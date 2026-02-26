import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: CameraUploadPage(),
    );
  }
}

class CameraUploadPage extends StatefulWidget {
  const CameraUploadPage({super.key});

  @override
  State<CameraUploadPage> createState() => _CameraUploadPageState();
}

class _CameraUploadPageState extends State<CameraUploadPage> {
  final _picker = ImagePicker();
  XFile? _picked;
  bool _uploading = false;
  String? _uploadedUrl;

  Future<void> _takePhoto() async {
    final x = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85, // 0~100 (간단 압축)
      maxWidth: 1600,   // 선택: 리사이즈
    );
    if (x == null) return;

    setState(() {
      _picked = x;
      _uploadedUrl = null;
    });
  }

  Future<void> _upload() async {
    if (_picked == null) return;

    setState(() => _uploading = true);
    try {
      final uri = Uri.parse('https://YOUR_SERVER.com/upload');

      final req = http.MultipartRequest('POST', uri);

      // 서버에서 기대하는 필드명(예: "file")에 맞추세요.
      req.files.add(await http.MultipartFile.fromPath('file', _picked!.path));

      // 필요하면 토큰/헤더 추가
      // req.headers['Authorization'] = 'Bearer ...';

      final streamed = await req.send();
      final resp = await http.Response.fromStream(streamed);

      if (resp.statusCode != 200) {
        throw Exception('업로드 실패: ${resp.statusCode} ${resp.body}');
      }

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      setState(() => _uploadedUrl = data['url'] as String?);
    } finally {
      setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = _picked == null ? null : File(_picked!.path);

    return Scaffold(
      appBar: AppBar(title: const Text('사진 촬영 & 업로드')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (file != null)
              Expanded(child: Image.file(file, fit: BoxFit.contain))
            else
              const Expanded(child: Center(child: Text('사진을 촬영하세요.'))),

            const SizedBox(height: 12),

            if (_uploadedUrl != null)
              SelectableText('업로드 URL: $_uploadedUrl'),

            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _uploading ? null : _takePhoto,
                    child: const Text('사진 찍기'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: (_uploading || _picked == null) ? null : _upload,
                    child: _uploading
                        ? const Text('업로드 중...')
                        : const Text('업로드'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}