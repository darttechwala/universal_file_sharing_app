import 'dart:io'
    show
        Directory,
        Platform,
        HttpServer,
        InternetAddress,
        File,
        NetworkInterface,
        InternetAddressType;

import 'package:easyfileshare/log.helper.dart' show log;
import 'package:easyfileshare/qrscan.page.dart' show QRScanPage;
import 'package:easyfileshare/transfer.model.dart' show TransferItem;
import 'package:file_picker/file_picker.dart' show FilePicker;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart'
    show
        StatefulWidget,
        State,
        Text,
        InputDecoration,
        BuildContext,
        Widget,
        SizedBox,
        Divider,
        EdgeInsets,
        TextEditingController,
        MainAxisSize,
        TextField,
        TextInputType,
        Column,
        Navigator,
        TextButton,
        ElevatedButton,
        AlertDialog,
        showDialog,
        AppBar,
        FontWeight,
        TextStyle,
        SelectableText,
        Axis,
        Chip,
        Padding,
        ListView,
        CrossAxisAlignment,
        LinearProgressIndicator,
        ListTile,
        Expanded,
        Scaffold,
        MaterialPageRoute;
import 'package:http/http.dart' as http show StreamedRequest;
import 'package:path_provider/path_provider.dart'
    show
        getExternalStorageDirectory,
        getApplicationDocumentsDirectory,
        getDownloadsDirectory;
import 'package:qr_flutter/qr_flutter.dart' show QrImageView;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final int port = 8080;
  String? myUrl;
  Directory? saveDir;
  List<String> connectedDevices = [];
  List<TransferItem> transfers = [];

  @override
  void initState() {
    super.initState();
    startServer();
  }

  // =================CLEAN UP=================
  Future<void> cleanupReceivedFiles() async {
    if (!await saveDir!.exists()) return;

    await for (var entity in saveDir!.list()) {
      try {
        await entity.delete(recursive: true);
      } catch (_) {}
    }

    print("[LOG] Received files cleaned");
  }

  // ================= SERVER =================

  Future<void> startServer() async {
    if (Platform.isAndroid) {
      saveDir =
          (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
    } else if (Platform.isIOS) {
      saveDir = await getApplicationDocumentsDirectory();
    } else if (Platform.isMacOS) {
      // macOS sandbox safe location
      saveDir = await getApplicationDocumentsDirectory();
    } else if (Platform.isWindows || Platform.isLinux) {
      final downloadsDir = await getDownloadsDirectory();
      saveDir = downloadsDir ?? await getApplicationDocumentsDirectory();
    } else {
      saveDir = await getApplicationDocumentsDirectory();
    }

    // create app folder
    saveDir = Directory("${saveDir!.path}/easyfileshare");
    // optional: auto cleanup
    if (kDebugMode) {
      print("Debug build detected");
      cleanupReceivedFiles();
    }
    if (!await saveDir!.exists()) {
      await saveDir!.create(recursive: true);
    }

    print("[LOG] SAVE DIRECTORY => ${saveDir!.path}");

    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);

    final ip = await _getLocalIP();

    setState(() {
      myUrl = "http://$ip:$port";
    });

    log("SERVER STARTED => $myUrl");

    server.listen((request) async {
      log("INCOMING CONNECTION FROM ${request.connectionInfo?.remoteAddress}");

      if (request.method != "POST") {
        log("IGNORED METHOD: ${request.method}");
        return;
      }

      final filename = request.headers.value("filename") ?? "unknown_file";

      final total =
          int.tryParse(request.headers.value("content-length") ?? "0") ?? 0;

      final device = request.connectionInfo?.remoteAddress.address ?? "Unknown";

      log("RECEIVING FILE => $filename");
      log("FROM DEVICE => $device");
      log("TOTAL SIZE => $total bytes");

      final item = TransferItem(
        device: device,
        fileName: filename,
        total: total,
        status: "receiving",
      );

      setState(() {
        connectedDevices.add(device);
        transfers.add(item);
      });

      final file = File("${saveDir!.path}/$filename");
      final sink = file.openWrite();

      try {
        await for (var chunk in request) {
          sink.add(chunk);

          setState(() {
            item.transferred += chunk.length;
          });

          log(
            "RECEIVING $filename -> ${item.transferred}/$total bytes "
            "(${(item.progress * 100).toStringAsFixed(1)}%)",
          );
        }

        await sink.close();

        setState(() {
          item.status = "completed";
        });

        log("RECEIVE COMPLETE => ${file.path}");

        request.response.write("OK");
        await request.response.close();
      } catch (e) {
        setState(() {
          item.status = "failed";
        });

        log("RECEIVE ERROR => $e");
      }
    });
  }

  Future<String> _getLocalIP() async {
    final interfaces = await NetworkInterface.list();

    for (var iface in interfaces) {
      if (iface.name.toLowerCase().contains("wi")) {
        for (var addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            log("USING IP => ${addr.address}");
            return addr.address;
          }
        }
      }
    }

    for (var iface in interfaces) {
      for (var addr in iface.addresses) {
        if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
          final ip = addr.address;

          print("[IP CHECK] Found: $ip on ${iface.name}");

          // ✅ Prefer hotspot/WiFi ranges like 10.x.x.x or 192.168.x.x
          if (ip.startsWith("10.") || ip.startsWith("192.168.")) {
            // ❌ Skip VMware virtual adapters
            if (iface.name.toLowerCase().contains("vmware")) {
              print("[SKIP] VMware adapter: $ip");
              continue;
            }

            print("[SELECTED IP] => $ip");
            return ip;
          }
        }
      }
    }

    for (var iface in interfaces) {
      for (var addr in iface.addresses) {
        if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
          log("FALLBACK IP => ${addr.address}");
          return addr.address;
        }
      }
    }

    return "0.0.0.0";
  }

  // ================= SEND =================

  Future<void> connectAndSend(String url) async {
    log("CONNECT & SEND TO => $url");

    final result = await FilePicker.platform.pickFiles(allowMultiple: true);

    if (result == null) {
      log("NO FILES SELECTED");
      return;
    }

    final files = result.files.map((f) => File(f.path!)).toList();

    for (var file in files) {
      final name = file.path.split(Platform.pathSeparator).last;
      final total = await file.length();

      log("START SENDING => $name ($total bytes)");

      final item = TransferItem(
        device: url,
        fileName: name,
        total: total,
        status: "sending",
      );

      setState(() {
        connectedDevices.add(url);
        transfers.add(item);
      });

      try {
        final request = http.StreamedRequest("POST", Uri.parse(url));

        request.headers["filename"] = name;
        request.headers["content-length"] = "$total";
        // Start request immediately
        final responseFuture = request.send();
        int sent = 0;
        await for (var chunk in file.openRead()) {
          request.sink.add(chunk);
          sent += chunk.length;
          setState(() {
            item.transferred = sent;
          });

          log(
            "SENDING $name -> ${item.transferred}/$total bytes "
            "(${(item.progress * 100).toStringAsFixed(1)}%)",
          );
        }

        await request.sink.close();

        final response = await responseFuture;

        log("SERVER RESPONSE => ${response.statusCode}");

        if (response.statusCode == 200) {
          setState(() => item.status = "completed");
          log("SEND COMPLETE => $name");
        } else {
          setState(() => item.status = "failed");
          log("SEND FAILED => $name");
        }
      } catch (e) {
        setState(() => item.status = "failed");

        log("SEND ERROR => $e");
      }
    }
  }

  Future<void> showManualConnectDialog() async {
    final ipController = TextEditingController();
    final portController = TextEditingController(text: "8080");

    await showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text("Connect Manually"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ipController,
                decoration: const InputDecoration(
                  labelText: "IP Address",
                  hintText: "192.168.1.5",
                ),
              ),

              TextField(
                controller: portController,
                decoration: const InputDecoration(labelText: "Port"),
                keyboardType: TextInputType.number,
              ),
            ],
          ),
          actions: [
            TextButton(
              child: const Text("Cancel"),
              onPressed: () => Navigator.pop(context),
            ),

            ElevatedButton(
              child: const Text("Connect"),
              onPressed: () async {
                final url =
                    "http://${ipController.text}:${portController.text}";

                Navigator.pop(context);

                await connectAndSend(url);
              },
            ),
          ],
        );
      },
    );
  }

  // ================= UI =================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Flutter File Share")),

      body: Column(
        children: [
          if (myUrl != null) ...[
            const SizedBox(height: 10),
            Text(
              "Your Address:",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SelectableText(myUrl!),
            QrImageView(data: myUrl!, size: 180),
          ],

          ElevatedButton(
            onPressed: () => _scanQr(context),
            child: const Text("Scan QR & Send Files"),
          ),
          ElevatedButton(
            onPressed: showManualConnectDialog,
            child: const Text("Enter Address Manually"),
          ),
          const Divider(),

          const Text("Connected Devices"),

          SizedBox(
            height: 60,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: connectedDevices
                  .toSet()
                  .map(
                    (d) => Padding(
                      padding: const EdgeInsets.all(8),
                      child: Chip(label: Text(d)),
                    ),
                  )
                  .toList(),
            ),
          ),

          const Divider(),

          const Text("Transfers"),

          Expanded(
            child: ListView.builder(
              itemCount: transfers.length,
              itemBuilder: (_, i) {
                final t = transfers[i];

                return ListTile(
                  title: Text(t.fileName),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LinearProgressIndicator(value: t.progress),
                      Text(
                        "${(t.transferred / 1024 / 1024).toStringAsFixed(1)} MB / "
                        "${(t.total / 1024 / 1024).toStringAsFixed(1)} MB "
                        "(${(t.progress * 100).toStringAsFixed(1)}%)",
                      ),
                    ],
                  ),
                  trailing: Text(t.status),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ================= QR =================

  Future<void> _scanQr(BuildContext context) async {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => QRScanPage(
          onScanned: (url) async {
            Navigator.pop(context);
            await connectAndSend(url);
          },
        ),
      ),
    );
  }
}
