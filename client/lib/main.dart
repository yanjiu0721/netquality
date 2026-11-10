// Copyright (C) 2026 灸 言
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';

import 'ui/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NetQualityApp());
}

class NetQualityApp extends StatelessWidget {
  const NetQualityApp({super.key});

  @override
  Widget build(BuildContext context) {
    const paper = Color(0xFFF3F1EC);
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1F4E79),
      surface: paper,
    );
    return MaterialApp(
      title: '网络质量探测',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: paper,
        useMaterial3: true,
        fontFamilyFallback: const [
          'NetQualityCJK',
          'Noto Sans CJK SC',
          'Noto Sans SC',
          'PingFang SC',
          'Microsoft YaHei',
          'Droid Sans Fallback',
        ],
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0xFFFFFCF7),
          isDense: true,
          border: OutlineInputBorder(),
        ),
        cardTheme: const CardThemeData(
          elevation: 0,
          color: Color(0xFFFFFCF7),
          margin: EdgeInsets.zero,
        ),
      ),
      home: const HomePage(),
    );
  }
}
