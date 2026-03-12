import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';


void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

/// 로컬 파일 저장 및 업로드 상태 관리를 위한 헬퍼 클래스
class LocalStorageHelper {
  // 1. 임시 파일을 영구 로컬 폴더로 복사
  static Future<String> saveAndFixPhotoLocally(int eventNo, String tempPath, int imageQuality) async {
    final dir = await getApplicationDocumentsDirectory();
    final eventDir = Directory('${dir.path}/events/$eventNo');
    if (!await eventDir.exists()) {
      await eventDir.create(recursive: true);
    }

    final fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
    final targetPath = '${eventDir.path}/$fileName';

    // 화질 설정에 따른 압축률 결정 (0: 속도, 1: 표준, 2: 원본/고품질)
    int compressQuality = 100;
    if (imageQuality == 0) compressQuality = 60; // 속도 위주 (용량 대폭 감소)
    else if (imageQuality == 1) compressQuality = 85; // 표준

    // compressAndGetFile은 기본적으로 EXIF 회전 정보를 읽어
    // 픽셀 자체를 올바른 방향으로 회전(autoCorrectionAngle: true)시켜 줍니다.
    final XFile? compressedFile = await FlutterImageCompress.compressAndGetFile(
      tempPath,
      targetPath,
      quality: compressQuality,
    );

    // 압축/회전이 실패하면 원본을 복사해서 반환
    if (compressedFile == null) {
      final savedImage = await File(tempPath).copy(targetPath);
      return savedImage.path;
    }

    return compressedFile.path;
  }

  // 2. 해당 이벤트의 로컬에 저장된 모든 사진 경로 불러오기
  static Future<List<String>> getSavedPhotos(int eventNo) async {
    final dir = await getApplicationDocumentsDirectory();
    final eventDir = Directory('${dir.path}/events/$eventNo');
    if (!await eventDir.exists()) return [];

    final files = eventDir.listSync().whereType<File>().where((f) => f.path.endsWith('.jpg')).toList();
    files.sort((a, b) => a.path.compareTo(b.path)); // 시간순 정렬
    return files.map((f) => f.path).toList();
  }

  // 3. 사진별 업로드 상태 SharedPreferences에 저장
  static Future<void> saveUploadStatus(String path, String status, {String? url}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('status_$path', status);
    if (url != null) {
      await prefs.setString('url_$path', url);
    }
  }

  // 4. 사진별 업로드 상태 불러오기
  static Future<Map<String, String?>> getUploadStatus(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final status = prefs.getString('status_$path') ?? 'pending';
    final url = prefs.getString('url_$path');
    return {'status': status, 'url': url};
  }
}

class AppConfig {
  static const _kBaseUrlKey = 'baseUrl';
  static const String defaultBaseUrl = 'http://sejongoff.iptime.org';

  static const _kCheckBeforeSaveKey = 'checkBeforeSave';
  static const bool defaultCheckBeforeSave = false;

  // 화질 설정 키 추가 (0: 속도, 1: 표준, 2: 고품질)
  static const _kImageQualityKey = 'imageQuality';
  static const int defaultImageQuality = 1;

  static Future<String> getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kBaseUrlKey) ?? defaultBaseUrl;
  }

  static Future<void> setBaseUrl(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBaseUrlKey, value);
  }

  static Future<bool> getCheckBeforeSave() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kCheckBeforeSaveKey) ?? defaultCheckBeforeSave;
  }

  static Future<void> setCheckBeforeSave(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCheckBeforeSaveKey, value);
  }

  // 화질 설정 Getter / Setter
  static Future<int> getImageQuality() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kImageQualityKey) ?? defaultImageQuality;
  }

  static Future<void> setImageQuality(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kImageQualityKey, value);
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Event Photo Uploader',
      theme: ThemeData(useMaterial3: true),
      home: const EventListPage(),
    );
  }
}

class ReservItem {
  final int reservNo;
  final DateTime reservFrom;
  final int visitCnt;
  final String? reservMemo;
  final String visitorName;
  final String status;

  const ReservItem({
    required this.reservNo,
    required this.reservFrom,
    required this.visitCnt,
    required this.reservMemo,
    required this.visitorName,
    required this.status,
  });

  factory ReservItem.fromJson(Map<String, dynamic> j) {
    return ReservItem(
      reservNo: j['reservNo'] as int,
      reservFrom: DateTime.parse(j['reservFrom'] as String),
      visitCnt: j['visitCnt'] as int,
      reservMemo: j['reservMemo'] as String?,
      visitorName: (j['visitorName'] as String?) ?? '',
      status: (j['status'] as String?) ?? '',
    );
  }
}

/// 설정 화면
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _controller = TextEditingController();
  bool _checkBeforeSave = false;
  double _imageQuality = 1.0; // 0.0: 속도, 1.0: 표준, 2.0: 고품질
  bool _saving = false;

  final List<String> _qualityLabels = ['속도 (1MB 이하)', '표준 (3MB 이하)', '고품질 (원본)'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final baseUrl = await AppConfig.getBaseUrl();
    final checkBeforeSave = await AppConfig.getCheckBeforeSave();
    final imageQuality = await AppConfig.getImageQuality();

    _controller.text = baseUrl;
    _checkBeforeSave = checkBeforeSave;
    _imageQuality = imageQuality.toDouble();

    if (mounted) setState(() {});
  }

  bool _looksLikeUrl(String s) {
    final v = s.trim();
    return v.startsWith('http://') || v.startsWith('https://');
  }

  Future<void> _save() async {
    final v = _controller.text.trim();
    if (!_looksLikeUrl(v)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('baseUrl은 http:// 또는 https:// 로 시작해야 합니다.')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await AppConfig.setBaseUrl(v);
      await AppConfig.setCheckBeforeSave(_checkBeforeSave);
      await AppConfig.setImageQuality(_imageQuality.toInt()); // 화질 설정 저장
      if (!mounted) return;
      Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'baseUrl',
                hintText: '예) http://10.0.2.2:8000',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            const SizedBox(height: 24),

            // 확인 후 저장 스위치
            SwitchListTile(
              title: const Text('촬영 후 사진 확인하기'),
              subtitle: const Text('체크 시 한 장씩 확인 후 업로드\n해제 시 확인 없이 연속 촬영 및 즉시 업로드'),
              value: _checkBeforeSave,
              contentPadding: EdgeInsets.zero,
              onChanged: (bool value) {
                setState(() {
                  _checkBeforeSave = value;
                });
              },
            ),
            const Divider(height: 32),

            // 사진 화질 슬라이더
            Text(
              '사진 화질: ${_qualityLabels[_imageQuality.toInt()]}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Slider(
              value: _imageQuality,
              min: 0,
              max: 2,
              divisions: 2,
              label: _qualityLabels[_imageQuality.toInt()],
              onChanged: (double value) {
                setState(() {
                  _imageQuality = value;
                });
              },
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('속도', style: TextStyle(color: Colors.grey)),
                  Text('표준', style: TextStyle(color: Colors.grey)),
                  Text('고품질', style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
            const SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? '저장 중...' : '저장'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 1) 초기 화면: 이벤트 목록
class EventListPage extends StatefulWidget {
  const EventListPage({super.key});

  @override
  State<EventListPage> createState() => _EventListPageState();
}

class _EventListPageState extends State<EventListPage> {
  late Future<List<ReservItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetchReservs();
  }

  Future<List<ReservItem>> _fetchReservs() async {
    final baseUrl = await AppConfig.getBaseUrl();
    final uri = Uri.parse('$baseUrl/api/get_reserv');

    final resp = await http.get(uri);
    if (resp.statusCode != 200) {
      throw Exception('예약 목록 조회 실패: ${resp.statusCode} ${resp.body}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = (data['reservs'] as List<dynamic>? ?? []);

    return list
        .map((e) => ReservItem.fromJson(e as Map<String, dynamic>))
        .where((r) => r.status == '1111111111' || r.status == '1000010000')
        .toList();
  }

  String _fmtDateTime(DateTime dt) {
    final d = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Future<void> _openSettings() async {
    final changed = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
    if (changed == true) {
      setState(() {
        _future = _fetchReservs();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('예약 목록'),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: _openSettings),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {
                _future = _fetchReservs();
              });
            },
          ),
        ],
      ),
      body: FutureBuilder<List<ReservItem>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('오류: ${snap.error}'));
          }

          final items = snap.data ?? [];
          if (items.isEmpty) {
            return const Center(child: Text('예약이 없습니다.'));
          }

          return RefreshIndicator(
            onRefresh: () async {
              final f = _fetchReservs();
              setState(() => _future = f);
              await f;
            },
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final r = items[i];
                final isVisiting = r.status == '1111111111';

                return Card(
                  child: ListTile(
                    title: Row(
                      children: [
                        Text('${r.visitorName}  (${r.visitCnt}명)'),
                        if (isVisiting) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.green.shade50,
                              border: Border.all(color: Colors.green),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              '방문중',
                              style: TextStyle(color: Colors.green, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text('예약번호: ${r.reservNo}\n예약시간: ${_fmtDateTime(r.reservFrom)}'),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CameraUploadPage(
                            eventNo: r.reservNo,
                            eventTitle: r.visitorName,
                          ),
                        ),
                      );
                      if (!mounted) return;
                      setState(() {
                        _future = _fetchReservs();
                      });
                    },
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// 2) 촬영/업로드 관리 화면
enum UploadState { pending, uploading, done, failed }

class ShotItem {
  final String localPath;
  UploadState state;
  String? uploadedUrl;
  String? error;

  ShotItem({
    required this.localPath,
    this.state = UploadState.pending,
    this.uploadedUrl,
    this.error,
  });
}

class CameraUploadPage extends StatefulWidget {
  final int eventNo;
  final String? eventTitle;

  const CameraUploadPage({
    super.key,
    required this.eventNo,
    this.eventTitle,
  });

  @override
  State<CameraUploadPage> createState() => _CameraUploadPageState();
}

class _CameraUploadPageState extends State<CameraUploadPage> {
  final PageController _pageController = PageController();
  final List<ShotItem> _shots = [];
  int _currentIndex = 0;
  int _uploadingCount = 0;

  @override
  void initState() {
    super.initState();
    _loadExistingPhotos(); // 화면 진입 시 기존 저장된 사진 불러오기
  }

  // 기존에 로컬에 저장된 사진과 상태를 불러오는 함수
  Future<void> _loadExistingPhotos() async {
    final paths = await LocalStorageHelper.getSavedPhotos(widget.eventNo);
    for (final path in paths) {
      final info = await LocalStorageHelper.getUploadStatus(path);
      final statusStr = info['status'];
      final url = info['url'];

      UploadState state = UploadState.pending;
      if (statusStr == 'uploading') state = UploadState.failed; // 앱 종료 등으로 중단된 경우 실패로 간주
      else if (statusStr == 'done') state = UploadState.done;
      else if (statusStr == 'failed') state = UploadState.failed;

      _shots.add(ShotItem(
        localPath: path,
        state: state,
        uploadedUrl: url,
      ));
    }

    if (_shots.isNotEmpty) {
      _currentIndex = _shots.length - 1;
    }
    if (mounted) setState(() {});
  }

  Future<String> _uploadPhotoAndGetAbsoluteUrl({
    required String baseUrl,
    required String filePath,
  }) async {
    final uri = Uri.parse('$baseUrl/api/eventphotoupload/${widget.eventNo}');
    final req = http.MultipartRequest('POST', uri);

    final mimeType = lookupMimeType(filePath) ?? 'image/jpeg';
    final parts = mimeType.split('/');

    req.files.add(await http.MultipartFile.fromPath(
      'photo',
      filePath,
      filename: p.basename(filePath),
      contentType: MediaType(parts[0], parts[1]),
    ));

    final streamed = await req.send();
    final resp = await http.Response.fromStream(streamed);

    if (resp.statusCode != 200) {
      throw Exception('업로드 실패: ${resp.statusCode} ${resp.body}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final urlPath = data['url'] as String?;
    if (urlPath == null || urlPath.isEmpty) {
      throw Exception('서버 응답에 url이 없습니다: ${resp.body}');
    }

    return urlPath.startsWith('http') ? urlPath : '$baseUrl$urlPath';
  }

  // 커스텀 카메라 화면 열기
  Future<void> _openCamera() async {
    final checkBeforeSave = await AppConfig.getCheckBeforeSave();
    final imageQuality = await AppConfig.getImageQuality(); // 화질 설정 불러오기

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CustomCameraScreen(
          checkBeforeSave: checkBeforeSave,
          imageQuality: imageQuality, // 카메라 화면에 화질 설정 전달
          onPictureTaken: (path) {
            _handleNewPhoto(path);
          },
        ),
      ),
    );
  }

  void _handleNewPhoto(String tempPath) async {
    // 1. 임시 파일을 로컬 영구 저장소로 복사
    final imageQuality = await AppConfig.getImageQuality();
    final persistentPath = await LocalStorageHelper.saveAndFixPhotoLocally(
        widget.eventNo,
        tempPath,
        imageQuality
    );
    await LocalStorageHelper.saveUploadStatus(persistentPath, 'uploading');

    final shot = ShotItem(localPath: persistentPath, state: UploadState.uploading);

    setState(() {
      _shots.add(shot);
      _currentIndex = _shots.length - 1;
      _uploadingCount++;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_currentIndex);
      }
    });

    try {
      final baseUrl = await AppConfig.getBaseUrl();
      final absoluteUrl = await _uploadPhotoAndGetAbsoluteUrl(
        baseUrl: baseUrl,
        filePath: persistentPath, // 영구 저장된 경로 사용
      );

      // 2. 업로드 성공 시 상태 기록
      await LocalStorageHelper.saveUploadStatus(persistentPath, 'done', url: absoluteUrl);

      if (mounted) {
        setState(() {
          shot.uploadedUrl = absoluteUrl;
          shot.state = UploadState.done;
          shot.error = null;
        });
      }
    } catch (e) {
      // 3. 업로드 실패 시 상태 기록
      await LocalStorageHelper.saveUploadStatus(persistentPath, 'failed');

      if (mounted) {
        setState(() {
          shot.state = UploadState.failed;
          shot.error = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _uploadingCount--;
        });
      }
    }
  }

  // 재시도 로직 수정
  Future<void> _retryUploadCurrent() async {
    if (_shots.isEmpty) return;
    final shot = _shots[_currentIndex];
    if (shot.state == UploadState.uploading) return;

    setState(() {
      shot.state = UploadState.uploading;
      shot.error = null;
      _uploadingCount++;
    });

    await LocalStorageHelper.saveUploadStatus(shot.localPath, 'uploading');

    try {
      final baseUrl = await AppConfig.getBaseUrl();
      final absoluteUrl = await _uploadPhotoAndGetAbsoluteUrl(
        baseUrl: baseUrl,
        filePath: shot.localPath,
      );

      await LocalStorageHelper.saveUploadStatus(shot.localPath, 'done', url: absoluteUrl);

      setState(() {
        shot.uploadedUrl = absoluteUrl;
        shot.state = UploadState.done;
      });
    } catch (e) {
      await LocalStorageHelper.saveUploadStatus(shot.localPath, 'failed');

      setState(() {
        shot.state = UploadState.failed;
        shot.error = e.toString();
      });
    } finally {
      if (mounted) setState(() => _uploadingCount--);
    }
  }


  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Widget _statusChip(ShotItem shot) {
    switch (shot.state) {
      case UploadState.uploading:
        return const Chip(label: Text('업로드 중'));
      case UploadState.done:
        return const Chip(label: Text('업로드 완료'));
      case UploadState.failed:
        return const Chip(label: Text('업로드 실패'));
      case UploadState.pending:
        return const Chip(label: Text('대기'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.eventTitle == null ? '촬영' : '촬영 - ${widget.eventTitle}';
    final currentShot = _shots.isEmpty ? null : _shots[_currentIndex];

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _uploadingCount > 0
                ? null
                : () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsPage()),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Card(
              child: ListTile(
                title: const Text('선택된 이벤트'),
                subtitle: Text('eventNo: ${widget.eventNo}'),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _shots.isEmpty
                  ? const Center(child: Text('아직 찍은 사진이 없습니다.\n아래 버튼으로 촬영하세요.'))
                  : Column(
                children: [
                  Row(
                    children: [
                      if (currentShot != null) _statusChip(currentShot),
                      const Spacer(),
                      Text('${_currentIndex + 1} / ${_shots.length}'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: PageView.builder(
                      controller: _pageController,
                      itemCount: _shots.length,
                      onPageChanged: (i) => setState(() => _currentIndex = i),
                      itemBuilder: (context, i) {
                        final shot = _shots[i];
                        final showNetwork = shot.uploadedUrl != null && shot.state == UploadState.done;

                        return ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (showNetwork)
                                Image.network(
                                  shot.uploadedUrl!,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) => Image.file(
                                    File(shot.localPath),
                                    fit: BoxFit.contain,
                                  ),
                                )
                              else
                                Image.file(
                                  File(shot.localPath),
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) =>
                                  const Center(child: Text('이미지를 불러올 수 없습니다.')),
                                ),
                              if (shot.state == UploadState.uploading)
                                const Center(child: CircularProgressIndicator()),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  if (currentShot != null && currentShot.state == UploadState.failed) ...[
                    const SizedBox(height: 8),
                    Text(
                      currentShot.error ?? '업로드 실패',
                      style: const TextStyle(color: Colors.red),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: _uploadingCount > 0 ? null : _retryUploadCurrent,
                        child: const Text('현재 사진 업로드 재시도'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _openCamera,
                child: const Text('카메라 열기 (사진 찍기)'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _uploadingCount > 0 ? null : () => Navigator.pop(context),
                child: const Text('이벤트 다시 선택'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 3) 커스텀 카메라 화면
class CustomCameraScreen extends StatefulWidget {
  final bool checkBeforeSave;
  final int imageQuality; // 화질 설정값 (0, 1, 2)
  final Function(String) onPictureTaken;

  const CustomCameraScreen({
    super.key,
    required this.checkBeforeSave,
    required this.imageQuality,
    required this.onPictureTaken,
  });

  @override
  State<CustomCameraScreen> createState() => _CustomCameraScreenState();
}

class _CustomCameraScreenState extends State<CustomCameraScreen> {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isReady = false;

  // 줌 관련 변수 추가
  double _minAvailableZoom = 1.0;
  double _maxAvailableZoom = 1.0;
  double _currentZoomLevel = 1.0;
  double _baseZoomLevel = 1.0; // 핀치 줌 계산용

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  // 설정된 화질에 따라 카메라 해상도(ResolutionPreset)를 결정하는 함수
  ResolutionPreset _getResolutionPreset() {
    switch (widget.imageQuality) {
      case 0: // 속도 (1MB 이하) -> 약 720p
        return ResolutionPreset.high;
      case 1: // 표준 (3MB 이하) -> 약 1080p
        return ResolutionPreset.veryHigh;
      case 2: // 고품질 (원본) -> 기기 최대 해상도
      default:
        return ResolutionPreset.max;
    }
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isNotEmpty) {
        _controller = CameraController(
          _cameras[0],
          _getResolutionPreset(),
          enableAudio: false,
        );
        await _controller!.initialize();

        // 카메라가 지원하는 최소/최대 줌 레벨 가져오기
        _maxAvailableZoom = await _controller!.getMaxZoomLevel();
        _minAvailableZoom = await _controller!.getMinZoomLevel();

        if (mounted) {
          setState(() {
            _isReady = true;
          });
        }
      }
    } catch (e) {
      debugPrint('카메라 초기화 오류: $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _takePicture() async {
    if (_controller == null || !_controller!.value.isInitialized ||
        _controller!.value.isTakingPicture) {
      return;
    }

    try {
      final XFile file = await _controller!.takePicture();

      if (widget.checkBeforeSave) {
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) =>
              AlertDialog(
                title: const Text('사진 확인'),
                content: Image.file(File(file.path)),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('다시 찍기'),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('저장 및 업로드'),
                  ),
                ],
              ),
        );

        if (confirmed == true) {
          widget.onPictureTaken(file.path);
          if (mounted) Navigator.pop(context);
        }
      } else {
        widget.onPictureTaken(file.path);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('사진이 촬영되어 업로드를 시작합니다.'),
              duration: Duration(milliseconds: 800),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('촬영 오류: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isReady || _controller == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    const double targetAspectRatio = 4 / 3;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // 1. 4:3 프리뷰 영역 + 핀치 줌(Pinch-to-zoom) 제스처
            Positioned.fill(
              child: GestureDetector(
                // 두 손가락 터치 시작 시 현재 줌 레벨 기억
                onScaleStart: (details) {
                  _baseZoomLevel = _currentZoomLevel;
                },
                // 두 손가락을 움직일 때 줌 레벨 계산 및 적용
                onScaleUpdate: (details) async {
                  if (_controller == null || !_isReady) return;

                  double targetZoom = _baseZoomLevel * details.scale;

                  // 기기가 지원하는 최소/최대 줌 범위를 벗어나지 않도록 제한
                  if (targetZoom < _minAvailableZoom) {
                    targetZoom = _minAvailableZoom;
                  } else if (targetZoom > _maxAvailableZoom) {
                    targetZoom = _maxAvailableZoom;
                  }

                  if (_currentZoomLevel != targetZoom) {
                    setState(() {
                      _currentZoomLevel = targetZoom;
                    });
                    await _controller!.setZoomLevel(_currentZoomLevel);
                  }
                },
                child: Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: AspectRatio(
                    aspectRatio: targetAspectRatio,
                    child: ClipRect(
                      child: FittedBox(
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                        child: SizedBox(
                          width: _controller!.value.aspectRatio,
                          height: 1.0,
                          child: CameraPreview(_controller!),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // 2. 닫기 버튼
            Positioned(
              top: 16,
              left: 16,
              child: CircleAvatar(
                backgroundColor: Colors.black54,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),

            // 3. 촬영 버튼
            Positioned(
              bottom: 32,
              left: 0,
              right: 0,
              child: Center(
                child: GestureDetector(
                  onTap: _takePicture,
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 4),
                      color: Colors.white.withOpacity(0.3),
                    ),
                  ),
                ),
              ),
            ),

            // 4. 현재 줌 배율 표시 (촬영 버튼 위쪽)
            Positioned(
              bottom: 120,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_currentZoomLevel.toStringAsFixed(1)}x',
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
              ),
            ),

            // 5. 연속 촬영 모드 안내 문구
            if (!widget.checkBeforeSave)
              Positioned(
                top: 24,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      '연속 촬영 모드 (확인 없이 바로 업로드)',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}