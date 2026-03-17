import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart'; // compute 사용을 위해 추가
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;
import 'dart:async';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

// 💡 업로드 타입을 구분하기 위한 Enum
enum UploadType { event, guestbook }

class LocalStorageHelper {
  // 1. 임시 파일을 영구 로컬 폴더로 복사 및 비율에 맞게 크롭
  static Future<String> saveAndFixPhotoLocally(
      int eventNo,
      String tempPath,
      int imageQuality,
      UploadType type,
      bool isPortraitRatio // 💡 UI에서 선택한 비율 정보
      ) async {
    final dir = await getApplicationDocumentsDirectory();
    final folderName = type == UploadType.event ? 'events' : 'guestbooks';
    final eventDir = Directory('${dir.path}/$folderName/$eventNo');

    if (!await eventDir.exists()) {
      await eventDir.create(recursive: true);
    }

    final fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
    final targetPath = '${eventDir.path}/$fileName';

    int compressQuality = 100;
    if (imageQuality == 0) compressQuality = 60;
    else if (imageQuality == 1) compressQuality = 85;

    // 1단계: 회전 보정 및 압축 (EXIF 방향이 적용된 똑바른 이미지가 됨)
    final XFile? compressedFile = await FlutterImageCompress.compressAndGetFile(
      tempPath,
      targetPath,
      quality: compressQuality,
    );

    String finalPath = compressedFile?.path ?? tempPath;

    // 2단계: UI가 멈추지 않도록 Isolate(백그라운드)에서 이미지 크롭 수행
    await compute(_cropImageInIsolate, {
      'path': finalPath,
      'isPortrait': isPortraitRatio,
    });

    return finalPath;
  }

  // 💡 백그라운드 이미지 크롭 로직 (선택한 비율과 실제 비율이 다르면 중앙을 기준으로 잘라냄)
  static void _cropImageInIsolate(Map<String, dynamic> params) {
    final String path = params['path'];
    final bool isPortrait = params['isPortrait'];

    try {
      final bytes = File(path).readAsBytesSync();
      img.Image? originalImage = img.decodeImage(bytes);

      if (originalImage != null) {
        int w = originalImage.width;
        int h = originalImage.height;

        double currentRatio = w / h;
        double targetRatio = isPortrait ? 3 / 4 : 4 / 3;

        // 오차가 5% 이상 나면 크롭 진행
        if ((currentRatio - targetRatio).abs() > 0.05) {
          int cropW = w;
          int cropH = h;

          if (currentRatio > targetRatio) {
            // 현재가 목표보다 더 넓음 (가로를 잘라야 함)
            cropW = (h * targetRatio).round();
          } else {
            // 현재가 목표보다 더 김 (세로를 잘라야 함)
            cropH = (w / targetRatio).round();
          }

          int offsetX = (w - cropW) ~/ 2;
          int offsetY = (h - cropH) ~/ 2;

          img.Image croppedImage = img.copyCrop(
              originalImage,
              x: offsetX,
              y: offsetY,
              width: cropW,
              height: cropH
          );

          File(path).writeAsBytesSync(img.encodeJpg(croppedImage, quality: 95));
        }
      }
    } catch (e) {
      debugPrint('Crop Error: $e');
    }
  }

  static Future<List<String>> getSavedPhotos(int eventNo, UploadType type) async {
    final dir = await getApplicationDocumentsDirectory();
    final folderName = type == UploadType.event ? 'events' : 'guestbooks';
    final eventDir = Directory('${dir.path}/$folderName/$eventNo');
    if (!await eventDir.exists()) return [];
    final files = eventDir.listSync().whereType<File>().where((f) => f.path.endsWith('.jpg')).toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    return files.map((f) => f.path).toList();
  }

  static Future<void> saveUploadStatus(String path, String status, {String? url}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('status_$path', status);
    if (url != null) await prefs.setString('url_$path', url);
  }

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

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _controller = TextEditingController();
  bool _checkBeforeSave = false;
  double _imageQuality = 1.0;
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

  Future<void> _save() async {
    final v = _controller.text.trim();
    if (!v.startsWith('http://') && !v.startsWith('https://')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('baseUrl은 http:// 또는 https:// 로 시작해야 합니다.')));
      return;
    }
    setState(() => _saving = true);
    try {
      await AppConfig.setBaseUrl(v);
      await AppConfig.setCheckBeforeSave(_checkBeforeSave);
      await AppConfig.setImageQuality(_imageQuality.toInt());
      if (!mounted) return;
      Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
              decoration: const InputDecoration(labelText: 'baseUrl', border: OutlineInputBorder()),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 24),
            SwitchListTile(
              title: const Text('촬영 후 사진 확인하기'),
              value: _checkBeforeSave,
              contentPadding: EdgeInsets.zero,
              onChanged: (bool value) => setState(() => _checkBeforeSave = value),
            ),
            const Divider(height: 32),
            Text('사진 화질: ${_qualityLabels[_imageQuality.toInt()]}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Slider(
              value: _imageQuality, min: 0, max: 2, divisions: 2,
              label: _qualityLabels[_imageQuality.toInt()],
              onChanged: (double value) => setState(() => _imageQuality = value),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(onPressed: _saving ? null : _save, child: Text(_saving ? '저장 중...' : '저장')),
            ),
          ],
        ),
      ),
    );
  }
}

class EventListPage extends StatefulWidget {
  const EventListPage({super.key});
  @override
  State<EventListPage> createState() => _EventListPageState();
}

class _EventListPageState extends State<EventListPage> with WidgetsBindingObserver {
  late Future<List<ReservItem>> _future;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _future = _fetchReservs();

    // 30초마다 백그라운드에서 자동으로 새로고침 (AJAX 처럼 동작)
    _timer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (mounted) {
        setState(() => _future = _fetchReservs());
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel(); // 화면이 종료될 때 타이머 해제
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() => _future = _fetchReservs());
    }
  }

  Future<List<ReservItem>> _fetchReservs() async {
    final baseUrl = await AppConfig.getBaseUrl();
    final uri = Uri.parse('$baseUrl/api/get_reserv');
    final resp = await http.get(uri);
    if (resp.statusCode != 200) throw Exception('예약 목록 조회 실패');
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = (data['reservs'] as List<dynamic>? ?? []);
    return list.map((e) => ReservItem.fromJson(e)).where((r) => r.status == '1111111111' || r.status == '1000010000').toList();
  }

  String _fmtDateTime(DateTime dt) {
    final d = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  String _getGDate(DateTime dt) {
    final d = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}';
  }

  void _showUploadOptions(ReservItem r) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            const Padding(padding: EdgeInsets.all(16.0), child: Text('어떤 사진을 촬영하시겠습니까?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            ListTile(
              leading: const Icon(Icons.photo_camera, color: Colors.blue),
              title: const Text('이벤트 사진 촬영'),
              onTap: () { Navigator.pop(ctx); _goToCamera(r, UploadType.event); },
            ),
            ListTile(
              leading: const Icon(Icons.menu_book, color: Colors.green),
              title: const Text('방명록 사진 촬영'),
              onTap: () { Navigator.pop(ctx); _goToCamera(r, UploadType.guestbook); },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _goToCamera(ReservItem r, UploadType type) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CameraUploadPage(
          eventNo: r.reservNo, eventTitle: r.visitorName, uploadType: type, gdate: _getGDate(r.reservFrom),
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _future = _fetchReservs());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('예약 목록'),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage()));
            if (!mounted) return;
            setState(() => _future = _fetchReservs());
          }),
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => setState(() => _future = _fetchReservs())),
        ],
      ),
      body: FutureBuilder<List<ReservItem>>(
        future: _future,
        builder: (context, snap) {
          // 기존 데이터가 없을 때(최초 로딩)만 로딩 인디케이터 표시
          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text('오류: ${snap.error}'));

          final items = snap.data ?? [];
          if (items.isEmpty) return const Center(child: Text('예약이 없습니다.'));

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              final r = items[i];
              return Card(
                child: ListTile(
                  title: Row(
                    children: [
                      Text('${r.visitorName} (${r.visitCnt}명)'),
                      if (r.status == '1111111111') ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.blueAccent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            '도착',
                            style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text('예약번호: ${r.reservNo}\n예약시간: ${_fmtDateTime(r.reservFrom)}'),
                  trailing: const Icon(Icons.camera_alt, color: Colors.blue),
                  onTap: () => _showUploadOptions(r),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

enum UploadState { pending, uploading, done, failed }

class ShotItem {
  final String localPath;
  UploadState state;
  String? uploadedUrl;
  String? error;
  ShotItem({required this.localPath, this.state = UploadState.pending, this.uploadedUrl, this.error});
}

class CameraUploadPage extends StatefulWidget {
  final int eventNo;
  final String? eventTitle;
  final UploadType uploadType;
  final String gdate;

  const CameraUploadPage({super.key, required this.eventNo, this.eventTitle, required this.uploadType, required this.gdate});

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
    _loadExistingPhotos();
  }

  Future<void> _loadExistingPhotos() async {
    final paths = await LocalStorageHelper.getSavedPhotos(widget.eventNo, widget.uploadType);
    for (final path in paths) {
      final info = await LocalStorageHelper.getUploadStatus(path);
      UploadState state = UploadState.pending;
      if (info['status'] == 'done') state = UploadState.done;
      else if (info['status'] == 'failed' || info['status'] == 'uploading') state = UploadState.failed;
      _shots.add(ShotItem(localPath: path, state: state, uploadedUrl: info['url']));
    }
    if (_shots.isNotEmpty) _currentIndex = _shots.length - 1;
    if (mounted) setState(() {});
  }

  Future<String> _uploadPhotoAndGetAbsoluteUrl({required String baseUrl, required String filePath}) async {
    final uri = widget.uploadType == UploadType.guestbook
        ? Uri.parse('$baseUrl/api/guestbookupload/${widget.gdate}/${widget.eventNo}')
        : Uri.parse('$baseUrl/api/eventphotoupload/${widget.eventNo}');

    final req = http.MultipartRequest('POST', uri);
    final mimeType = lookupMimeType(filePath) ?? 'image/jpeg';
    final parts = mimeType.split('/');
    req.files.add(await http.MultipartFile.fromPath('photo', filePath, filename: p.basename(filePath), contentType: MediaType(parts[0], parts[1])));
    final streamed = await req.send();
    final resp = await http.Response.fromStream(streamed);

    if (resp.statusCode != 200) throw Exception('업로드 실패: ${resp.statusCode}');
    final data = jsonDecode(resp.body);
    final urlPath = data['url'] as String?;
    return urlPath!.startsWith('http') ? urlPath : '$baseUrl$urlPath';
  }

  Future<void> _openCamera() async {
    final checkBeforeSave = await AppConfig.getCheckBeforeSave();
    final imageQuality = await AppConfig.getImageQuality();

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CustomCameraScreen(
          checkBeforeSave: checkBeforeSave,
          imageQuality: imageQuality,
          uploadType: widget.uploadType,
          onPictureTaken: (path, isPortrait) { // 💡 비율 정보 함께 전달
            _handleNewPhoto(path, isPortrait);
          },
        ),
      ),
    );
  }

  void _handleNewPhoto(String tempPath, bool isPortraitRatio) async {
    final imageQuality = await AppConfig.getImageQuality();

    // 💡 비율 정보를 넘겨주어 백그라운드에서 크롭 수행
    final persistentPath = await LocalStorageHelper.saveAndFixPhotoLocally(
        widget.eventNo, tempPath, imageQuality, widget.uploadType, isPortraitRatio
    );

    await LocalStorageHelper.saveUploadStatus(persistentPath, 'uploading');
    final shot = ShotItem(localPath: persistentPath, state: UploadState.uploading);

    setState(() {
      _shots.add(shot);
      _currentIndex = _shots.length - 1;
      _uploadingCount++;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) _pageController.jumpToPage(_currentIndex);
    });

    try {
      final baseUrl = await AppConfig.getBaseUrl();
      final absoluteUrl = await _uploadPhotoAndGetAbsoluteUrl(baseUrl: baseUrl, filePath: persistentPath);
      await LocalStorageHelper.saveUploadStatus(persistentPath, 'done', url: absoluteUrl);
      if (mounted) setState(() { shot.uploadedUrl = absoluteUrl; shot.state = UploadState.done; });
    } catch (e) {
      await LocalStorageHelper.saveUploadStatus(persistentPath, 'failed');
      if (mounted) setState(() { shot.state = UploadState.failed; shot.error = e.toString(); });
    } finally {
      if (mounted) setState(() => _uploadingCount--);
    }
  }

  @override
  Widget build(BuildContext context) {
    final typeStr = widget.uploadType == UploadType.event ? '이벤트' : '방명록';
    return Scaffold(
      appBar: AppBar(title: Text('[$typeStr] ${widget.eventTitle ?? ''}')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: _shots.isEmpty
                  ? const Center(child: Text('아직 찍은 사진이 없습니다.'))
                  : PageView.builder(
                controller: _pageController,
                itemCount: _shots.length,
                onPageChanged: (i) => setState(() => _currentIndex = i),
                itemBuilder: (context, i) {
                  final shot = _shots[i];
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        shot.uploadedUrl != null && shot.state == UploadState.done
                            ? Image.network(shot.uploadedUrl!, fit: BoxFit.contain)
                            : Image.file(File(shot.localPath), fit: BoxFit.contain),
                        if (shot.state == UploadState.uploading)
                          const Center(child: CircularProgressIndicator()),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(onPressed: _openCamera, child: const Text('카메라 열기 (사진 찍기)')),
            ),
          ],
        ),
      ),
    );
  }
}

class CustomCameraScreen extends StatefulWidget {
  final bool checkBeforeSave;
  final int imageQuality;
  final UploadType uploadType;
  final Function(String, bool) onPictureTaken; // 💡 비율 상태 전달

  const CustomCameraScreen({
    super.key,
    required this.checkBeforeSave,
    required this.imageQuality,
    required this.uploadType,
    required this.onPictureTaken,
  });

  @override
  State<CustomCameraScreen> createState() => _CustomCameraScreenState();
}

class _CustomCameraScreenState extends State<CustomCameraScreen> {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isReady = false;
  bool _isPortraitRatio = true;

  double _minAvailableZoom = 1.0;
  double _maxAvailableZoom = 1.0;
  double _currentZoomLevel = 1.0;
  double _baseZoomLevel = 1.0;

  @override
  void initState() {
    super.initState();
    // 방명록은 세로(3:4) 기본, 이벤트는 가로(4:3) 기본
    _isPortraitRatio = widget.uploadType == UploadType.guestbook;
    _initCamera();
  }

  ResolutionPreset _getResolutionPreset() {
    switch (widget.imageQuality) {
      case 0: return ResolutionPreset.high;
      case 1: return ResolutionPreset.veryHigh;
      case 2: default: return ResolutionPreset.max;
    }
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isNotEmpty) {
        _controller = CameraController(
            _cameras[0],
            _getResolutionPreset(),
            enableAudio: false
        );
        await _controller!.initialize();

        _maxAvailableZoom = await _controller!.getMaxZoomLevel();
        _minAvailableZoom = await _controller!.getMinZoomLevel();

        if (mounted) setState(() => _isReady = true);
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
    if (_controller == null || !_controller!.value.isInitialized || _controller!.value.isTakingPicture) return;
    try {
      final XFile file = await _controller!.takePicture();

      if (widget.checkBeforeSave) {
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('사진 확인'),
            content: Image.file(File(file.path)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('다시 찍기')),
              ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('저장 및 업로드')),
            ],
          ),
        );
        if (confirmed == true) {
          widget.onPictureTaken(file.path, _isPortraitRatio); // 💡 선택된 비율 전달
          if (mounted) Navigator.pop(context);
        }
      } else {
        widget.onPictureTaken(file.path, _isPortraitRatio); // 💡 선택된 비율 전달
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('사진이 촬영되어 업로드를 시작합니다.'), duration: Duration(milliseconds: 800)),
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

    // 💡 현재 설정된 비율에 따라 프리뷰 영역의 AspectRatio 계산
    final double targetAspectRatio = _isPortraitRatio ? 3 / 4 : 4 / 3;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // 1. 프리뷰 영역 + 핀치 줌
            Positioned.fill(
              child: GestureDetector(
                onScaleStart: (details) => _baseZoomLevel = _currentZoomLevel,
                onScaleUpdate: (details) async {
                  if (_controller == null || !_isReady) return;
                  double targetZoom = _baseZoomLevel * details.scale;
                  if (targetZoom < _minAvailableZoom) targetZoom = _minAvailableZoom;
                  else if (targetZoom > _maxAvailableZoom) targetZoom = _maxAvailableZoom;

                  if (_currentZoomLevel != targetZoom) {
                    setState(() => _currentZoomLevel = targetZoom);
                    await _controller!.setZoomLevel(_currentZoomLevel);
                  }
                },
                child: Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: AspectRatio(
                    aspectRatio: targetAspectRatio, // 💡 동적 비율 적용
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

            // 2. 상단 툴바 (닫기 버튼 & 비율 전환 버튼)
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CircleAvatar(
                    backgroundColor: Colors.black54,
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                  // 💡 가로/세로 비율 전환 버튼
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _isPortraitRatio = !_isPortraitRatio;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white54),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _isPortraitRatio ? Icons.crop_portrait : Icons.crop_landscape,
                            color: Colors.white,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _isPortraitRatio ? '세로 (3:4)' : '가로 (4:3)',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
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

            // 4. 현재 줌 배율 표시
            Positioned(
              bottom: 120,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
                top: 80,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
