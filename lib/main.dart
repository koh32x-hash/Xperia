import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';

void main() {
  runApp(const LeafMeterApp());
}

class LeafMeterApp extends StatelessWidget {
  const LeafMeterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Leaf Mini Meter (OBDLink LX)',
      theme: ThemeData.dark(),
      home: const MeterScreen(),
    );
  }
}

class MeterScreen extends StatefulWidget {
  const MeterScreen({super.key});

  @override
  State<MeterScreen> createState() => _MeterScreenState();
}

class _MeterScreenState extends State<MeterScreen> {
  BluetoothConnection? connection;
  bool isConnected = false;
  bool isConnecting = false;
  bool isDemoMode = false;
  List<BluetoothDevice> devices = [];
  BluetoothDevice? selectedDevice;

  // リーフの表示データ
  String socVal = "--.-";
  String sohVal = "--.-";
  String currentVal = "0.0";
  String tempVal = "--";
  String statusMsg = "未接続 (デバイスを選んで接続してください)";

  Timer? pollTimer;

  @override
  void initState() {
    super.initState();
    getBondedDevices();
  }

  Future<void> getBondedDevices() async {
    try {
      List<BluetoothDevice> bonded = await FlutterBluetoothSerial.instance.getBondedDevices();
      setState(() {
        devices = bonded;
        if (devices.isNotEmpty) {
          selectedDevice = devices.first;
        }
      });
    } catch (e) {
      setState(() {
        statusMsg = "Bluetooth取得エラー: $e";
      });
    }
  }

  void toggleDemoMode() {
    setState(() {
      isDemoMode = !isDemoMode;
      if (isDemoMode) {
        statusMsg = "【デモモード作動中】実機なしでメーター動作確認できます";
        socVal = "78.4";
        sohVal = "92.1";
        currentVal = "-15.4";
        tempVal = "28";
        startDemoLoop();
      } else {
        pollTimer?.cancel();
        statusMsg = "デモモード解除";
      }
    });
  }

  void startDemoLoop() {
    pollTimer?.cancel();
    pollTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!isDemoMode) {
        timer.cancel();
        return;
      }
      setState(() {
        currentVal = ((-25.0) + (DateTime.now().second % 10)).toStringAsFixed(1);
        tempVal = (27 + (DateTime.now().second % 3)).toString();
      });
    });
  }

  Future<void> connectToDevice() async {
    if (selectedDevice == null) return;
    setState(() {
      isConnecting = true;
      statusMsg = "接続中... (${selectedDevice!.name})";
    });

    try {
      BluetoothConnection conn = await BluetoothConnection.toAddress(selectedDevice!.address);
      setState(() {
        connection = conn;
        isConnected = true;
        isConnecting = false;
        statusMsg = "OBDLink LX 接続成功！";
      });

      await sendInitCommands();
      startObdPolling();

      conn.input!.listen(_onDataReceived).onDone(() {
        setState(() {
          isConnected = false;
          statusMsg = "接続が切断されました";
        });
      });
    } catch (e) {
      setState(() {
        isConnecting = false;
        isConnected = false;
        statusMsg = "接続失敗: $e";
      });
    }
  }

  Future<void> sendInitCommands() async {
    if (connection == null) return;
    try {
      connection!.output.add(utf8.encode("ATZ\r"));
      await connection!.output.allSent;
      await Future.delayed(const Duration(milliseconds: 500));

      connection!.output.add(utf8.encode("ATSP6\r")); // CAN 11bit 500kbps
      await connection!.output.allSent;
      await Future.delayed(const Duration(milliseconds: 200));

      connection!.output.add(utf8.encode("ATSH 79B\r")); // LBC header
      await connection!.output.allSent;
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (e) {
      print("Init error: $e");
    }
  }

  void startObdPolling() {
    pollTimer?.cancel();
    pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!isConnected || connection == null) {
        timer.cancel();
        return;
      }
      try {
        connection!.output.add(utf8.encode("21 01\r"));
        await connection!.output.allSent;
      } catch (e) {
        print("Poll error: $e");
      }
    });
  }

  void _onDataReceived(Uint8List data) {
    String resp = ascii.decode(data);
    setState(() {
      statusMsg = "受信: ${resp.replaceAll('\r', ' ').trim()}";
    });
  }

  @override
  void dispose() {
    pollTimer?.cancel();
    connection?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Leaf Mini Monitor (OBDLink LX)'),
        actions: [
          IconButton(
            icon: Icon(isDemoMode ? Icons.stop : Icons.play_circle),
            onPressed: toggleDemoMode,
            tooltip: 'デモモード切替',
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButton<BluetoothDevice>(
                            isExpanded: true,
                            value: selectedDevice,
                            items: devices.map((d) {
                              return DropdownMenuItem(
                                value: d,
                                child: Text('${d.name ?? '不明'} (${d.address})'),
                              );
                            }).toList(),
                            onChanged: (val) {
                              setState(() {
                                selectedDevice = val;
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          style: ButtonStyle(
                            backgroundColor: WidgetStateProperty.all(isConnected ? Colors.red : Colors.green),
                          ),
                          onPressed: isConnecting ? null : (isConnected ? () { connection?.close(); setState(() => isConnected = false); } : connectToDevice),
                          child: Text(isConnected ? '切断' : '接続'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(statusMsg, style: TextStyle(fontSize: 12, color: isConnected ? Colors.greenAccent : Colors.orangeAccent)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 1.3,
                children: [
                  buildMeterCard("実 SOC", "$socVal %", Colors.blueAccent),
                  buildMeterCard("SOH (健康度)", "$sohVal %", Colors.tealAccent),
                  buildMeterCard("入出力電流", "$currentVal A", Colors.amberAccent),
                  buildMeterCard("バッテリー温度", "$tempVal ℃", Colors.deepOrangeAccent),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildMeterCard(String title, String value, Color color) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(title, style: const TextStyle(fontSize: 14, color: Colors.grey)),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
