import 'package:flutter/material.dart'
    show StatelessWidget, BuildContext, Widget, Text, AppBar, Scaffold;
import 'package:mobile_scanner/mobile_scanner.dart' show MobileScanner;

import 'log.helper.dart' show log;

class QRScanPage extends StatelessWidget {
  final Function(String) onScanned;

  const QRScanPage({super.key, required this.onScanned});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Scan Receiver QR")),
      body: MobileScanner(
        onDetect: (barcode) {
          final url = barcode.barcodes.first.rawValue;
          if (url != null) {
            log("QR DETECTED => $url");
            onScanned(url);
          }
        },
      ),
    );
  }
}
