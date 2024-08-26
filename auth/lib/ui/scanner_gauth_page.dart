import 'package:ente_auth/l10n/l10n.dart';
import 'package:ente_auth/models/code.dart';
import 'package:ente_auth/ui/settings/data/import/google_auth_import.dart';
import 'package:ente_auth/utils/toast_util.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class ScannerGoogleAuthPage extends StatefulWidget {
  const ScannerGoogleAuthPage({super.key});

  @override
  State<ScannerGoogleAuthPage> createState() => ScannerGoogleAuthPageState();
}

class ScannerGoogleAuthPageState extends State<ScannerGoogleAuthPage> {
  late final MobileScannerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      autoStart: true,
      formats: const [BarcodeFormat.qrCode],
      returnImage: false,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.scan),
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            flex: 5,
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
            ),
          ),
          Expanded(
            flex: 1,
            child: Center(
              child: Text(l10n.scanACode),
            ),
          ),
        ],
      ),
    );
  }

  void _onDetect(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final data = barcode.rawValue;
      if (data == null) {
        showToast(context, context.l10n.invalidQRCode);
        continue;
      }

      if (!data.startsWith(kGoogleAuthExportPrefix)) {
        showToast(context, context.l10n.invalidQRCode);
        continue;
      }

      final List<Code> codes;
      try {
        codes = parseGoogleAuth(data);
      } catch (e) {
        showToast(context, context.l10n.invalidQRCode);
        continue;
      }

      Navigator.of(context).pop<List<Code>>(codes);
      return;
    }
  }
}
