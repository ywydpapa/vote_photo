import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
}

class AppConfig {
  static const _kBaseUrlKey = 'baseUrl';
  static const String defaultBaseUrl = 'http://10.0.2.2:8000';

  static Future<String> getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kBaseUrlKey) ?? defaultBaseUrl;
  }

  static Future<void> setBaseUrl(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBaseUrlKey, value);
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

class EventItem {
  final int eventNo;
  final String title;
  final String? subtitle;

  const EventItem({
    required this.eventNo,
    required this.title,
    this.subtitle,
  });
}

/// 설정 화면: baseUrl 편집
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _controller = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final baseUrl = await AppConfig.getBaseUrl();
    _controller.text = baseUrl;
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
      if (!mounted) return;
      Navigator.pop(context, true); // 저장됨
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
      appBar: AppBar(
        title: const Text('설정'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
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
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? '저장 중...' : '저장'),
              ),
            ),
            const SizedBox(height: 12),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '- Android 에뮬레이터: http://10.0.2.2:8000\n'
                    '- iOS 시뮬레이터: http://127.0.0.1:8000\n'
                    '- 실기기: 같은 Wi-Fi의 PC IP (예: http://192.168.0.10:8000)',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 1) 초기 화면: 이벤트 목록(카드) + 설정 진입
class EventListPage extends StatelessWidget {
  const EventListPage({super.key});

  final List<EventItem> _events = const [
    EventItem(eventNo: 101, title: '봄 축제', subtitle: '2026-03-01 ~ 2026-03-03'),
    EventItem(eventNo: 102, title: '개막식', subtitle: '메인 홀'),
    EventItem(eventNo: 103, title: '세미나', subtitle: 'A룸'),
    EventItem(eventNo: 104, title: '폐막식', subtitle: '야외 무대'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('이벤트 선택'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsPage()),
              );
            },
          ),
        ],
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _events.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, i) {
          final e = _events[i];
          return Card(
            child: ListTile(
              title: Text(e.title),
              subtitle: Text('eventNo: ${e.eventNo}${e.subtitle != null ? '\n${e.subtitle}' : ''}'),
              isThreeLine: e.subtitle != null,
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CameraUploadPage(
                      eventNo: e.eventNo,
                      eventTitle: e.title,
                    ),
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

/// 2) 촬영/업로드 + 이전 사진 스와이프
enum UploadState { pending, uploading, done, failed }

class ShotItem {
  final String localPath;
  UploadState state;
  String? uploadedUrl; // 서버가 반환한 url (절대/상대)
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
  final _picker = ImagePicker();
  final PageController _pageController = PageController();

  bool _uploading = false;

  final List<ShotItem> _shots = [];
  int _currentIndex = 0;

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

  Future<void> _takeAndUploadOnce() async {
    if (_uploading) return;

    final x = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
      maxWidth: 1600,
    );
    if (x == null) return;

    final shot = ShotItem(localPath: x.path, state: UploadState.uploading);

    setState(() {
      _shots.add(shot);
      _currentIndex = _shots.length - 1;
      _uploading = true;
    });

    await Future.delayed(const Duration(milliseconds: 50));
    if (mounted) _pageController.jumpToPage(_currentIndex);

    try {
      final baseUrl = await AppConfig.getBaseUrl();
      final absoluteUrl = await _uploadPhotoAndGetAbsoluteUrl(
        baseUrl: baseUrl,
        filePath: x.path,
      );

      setState(() {
        shot.uploadedUrl = absoluteUrl;
        shot.state = UploadState.done;
        shot.error = null;
      });
    } catch (e) {
      setState(() {
        shot.state = UploadState.failed;
        shot.error = e.toString();
      });
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _retryUploadCurrent() async {
    if (_shots.isEmpty || _uploading) return;
    final shot = _shots[_currentIndex];

    setState(() {
      shot.state = UploadState.uploading;
      shot.error = null;
      _uploading = true;
    });

    try {
      final baseUrl = await AppConfig.getBaseUrl();
      final absoluteUrl = await _uploadPhotoAndGetAbsoluteUrl(
        baseUrl: baseUrl,
        filePath: shot.localPath,
      );

      setState(() {
        shot.uploadedUrl = absoluteUrl;
        shot.state = UploadState.done;
      });
    } catch (e) {
      setState(() {
        shot.state = UploadState.failed;
        shot.error = e.toString();
      });
    } finally {
      if (mounted) setState(() => _uploading = false);
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
      default:
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
            onPressed: _uploading
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
                        onPressed: _uploading ? null : _retryUploadCurrent,
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
                onPressed: _uploading ? null : _takeAndUploadOnce,
                child: Text(_uploading ? '업로드 중...' : '사진 찍기'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _uploading ? null : () => Navigator.pop(context),
                child: const Text('이벤트 다시 선택'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
