import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:record/record.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const AirMicClientApp());
}

class AirMicClientApp extends StatelessWidget {
  const AirMicClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AirMic Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF080B11),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFF00E676),
          surface: Color(0xFF0F131A),
          error: Color(0xFFFF1744),
        ),
        cardTheme: const CardThemeData(
          color: Color(0xFF0F131A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
            side: BorderSide(color: Colors.white10, width: 1),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.03),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.white12),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.white10),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF00E5FF)),
          ),
          hintStyle: const TextStyle(color: Colors.white30),
        ),
      ),
      home: const ConnectionScreen(),
    );
  }
}

enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  failed,
}

class DiscoveredHost {
  final String ip;
  final int port;
  final String deviceName;
  final String code;
  final DateTime lastSeen;

  DiscoveredHost({
    required this.ip,
    required this.port,
    required this.deviceName,
    required this.code,
    required this.lastSeen,
  });
}

class PairedDevice {
  final String deviceName;
  final String lastKnownIp;
  final String pairingIdentifier;

  PairedDevice({
    required this.deviceName,
    required this.lastKnownIp,
    required this.pairingIdentifier,
  });

  Map<String, dynamic> toJson() => {
    "deviceName": deviceName,
    "lastKnownIp": lastKnownIp,
    "pairingIdentifier": pairingIdentifier,
  };

  factory PairedDevice.fromJson(Map<String, dynamic> json) => PairedDevice(
    deviceName: json["deviceName"] ?? "",
    lastKnownIp: json["lastKnownIp"] ?? "",
    pairingIdentifier: json["pairingIdentifier"] ?? "",
  );
}

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final TextEditingController _otpController = TextEditingController();
  ConnectionStatus _status = ConnectionStatus.disconnected;
  
  String _deviceModel = "Android Device";
  String _androidVersion = "Unknown";
  Socket? _socket;
  String _activePcIp = "";

  // Audio Recording & UDP Streaming Variables
  final AudioRecorder _audioRecorder = AudioRecorder();
  Timer? _statsTimer;

  // Real-time Audio Device Hot-Swapping Monitor
  Set<String> _previousDeviceIds = {};
  Timer? _deviceMonitorTimer;
  InputDevice? _activeInputDevice;

  // Bluetooth SCO Audio Link Control Channel
  static const _bluetoothChannel = MethodChannel("com.ayush.airmic/bluetooth");
  String _scoState = "disconnected";

  // Speaker Stream (PC → Phone) Playback
  static const _speakerChannel = MethodChannel("com.ayush.airmic/speaker");
  double _speakerBitrate = 0.0;
  int _speakerPackets = 0;
  bool _isSpeakerPlaying = false;
  Timer? _speakerStatsTimer;
  int _lastSpeakerBytes = 0;
  DateTime? _lastSpeakerStatsTime;

  Future<void> _updateAudioStream() async {
    if (_status != ConnectionStatus.connected) return;
    final isBluetooth = _activeInputDevice != null &&
                        (_activeInputDevice!.type == InputDeviceType.bluetoothSco ||
                         _activeInputDevice!.type == InputDeviceType.bluetoothLe ||
                         _activeInputDevice!.type == InputDeviceType.bluetoothA2dp);
    try {
      await _speakerChannel.invokeMethod("startAudioStream", {
        "pcIp": _activePcIp,
        "isBluetooth": isBluetooth,
        "enableSpeakers": true,
        "enableMic": _isStreaming,
        if (_selectedMicDevice != null) "selectedMicDeviceId": _selectedMicDevice!.id,
      });
    } catch (e) {
      debugPrint("Failed to update native audio stream: $e");
    }
  }

  // Discovery & Pairing Variables
  RawDatagramSocket? _discoverySocket;
  final Map<String, DiscoveredHost> _discoveredHosts = {}; // OTP Code -> Host
  Map<String, PairedDevice> _pairedDevices = {}; // DeviceName -> PairedDevice
  Timer? _discoveryCleanupTimer;
  static const String _pairedDevicesKey = "airmic_paired_devices";

  bool _isStreaming = false;
  int _packetsSent = 0;
  double _currentBitrate = 0.0;
  int _lastMicBytes = 0;
  DateTime? _lastMicStatsTime;

  // Manual microphone device selection
  List<InputDevice> _availableInputDevices = [];
  InputDevice? _selectedMicDevice;

  @override
  void initState() {
    super.initState();
    _loadDeviceInfo();
    _initBackgroundMode();
    _loadPairedDevices();
    _startDiscovery();
    _otpController.addListener(() {
      setState(() {});
    });

    _speakerChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case "onSpeakerStatusChanged":
          final isPlaying = call.arguments as bool;
          if (mounted) {
            setState(() {
              _isSpeakerPlaying = isPlaying;
            });
          }
          break;
        case "onMicStats":
          final args = call.arguments as Map<dynamic, dynamic>;
          final packets = args["packetsSent"] as int;
          final bytes = args["bytesSent"] as int;
          if (mounted) {
            setState(() {
              _packetsSent = packets;
              if (_lastMicBytes != 0) {
                final now = DateTime.now();
                final elapsed = _lastMicStatsTime != null
                    ? now.difference(_lastMicStatsTime!).inMilliseconds / 1000.0
                    : 0.5;
                if (elapsed > 0) {
                  final deltaBytes = bytes - _lastMicBytes;
                  _currentBitrate = (deltaBytes * 8 / elapsed) / 1000.0;
                }
              }
              _lastMicBytes = bytes;
              _lastMicStatsTime = DateTime.now();
            });
          }
          break;
        case "onSpeakerStats":
          final sArgs = call.arguments as Map<dynamic, dynamic>;
          final sPackets = sArgs["packets"] as int;
          final sBytes = sArgs["bytesReceived"] as int;
          if (mounted) {
            setState(() {
              _speakerPackets = sPackets;
              if (_lastSpeakerBytes != 0) {
                final now = DateTime.now();
                final elapsed = _lastSpeakerStatsTime != null
                    ? now.difference(_lastSpeakerStatsTime!).inMilliseconds / 1000.0
                    : 0.5;
                if (elapsed > 0) {
                  final deltaBytes = sBytes - _lastSpeakerBytes;
                  _speakerBitrate = (deltaBytes * 8 / elapsed) / 1000.0;
                }
              }
              _lastSpeakerBytes = sBytes;
              _lastSpeakerStatsTime = DateTime.now();
            });
          }
          break;
        case "onScoStateChanged":
          final state = call.arguments as String;
          debugPrint("Bluetooth SCO state changed to: $state");
          if (mounted) {
            setState(() {
              _scoState = state;
            });
          }
          break;
        case "onDevicesChanged":
          debugPrint("Audio devices changed callback triggered from native");
          _refreshDevices();
          break;
      }
    });
  }

  Future<void> _loadDeviceInfo() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        setState(() {
          _deviceModel = androidInfo.model;
          _androidVersion = androidInfo.version.release;
        });
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        setState(() {
          _deviceModel = iosInfo.name;
          _androidVersion = iosInfo.systemVersion;
        });
      }
    } catch (e) {
      debugPrint("Failed to load device info: $e");
    }
  }

  Future<void> _initBackgroundMode() async {
    const config = FlutterBackgroundAndroidConfig(
      notificationTitle: "AirMic Stream Controller",
      notificationText: "Streaming live microphone audio in the background",
      notificationImportance: AndroidNotificationImportance.normal,
      notificationIcon: AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
    );
    try {
      bool initialized = await FlutterBackground.initialize(androidConfig: config);
      debugPrint("FlutterBackground initialized: $initialized");
    } catch (e) {
      debugPrint("Failed to initialize background mode: $e");
    }
  }

  Future<void> _loadPairedDevices() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_pairedDevicesKey);
      if (list != null) {
        final map = <String, PairedDevice>{};
        for (var item in list) {
          try {
            final decoded = jsonDecode(item);
            final device = PairedDevice.fromJson(decoded);
            map[device.deviceName] = device;
          } catch (e) {
            debugPrint("Failed to decode paired device JSON: $e");
          }
        }
        setState(() {
          _pairedDevices = map;
        });
      }
    } catch (e) {
      debugPrint("Failed to load paired devices: $e");
    }
  }

  Future<void> _savePairedDevices() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _pairedDevices.values.map((d) => jsonEncode(d.toJson())).toList();
      await prefs.setStringList(_pairedDevicesKey, list);
    } catch (e) {
      debugPrint("Failed to save paired devices: $e");
    }
  }

  Future<void> _startDiscovery() async {
    try {
      _discoverySocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 9092);
      _discoverySocket!.broadcastEnabled = true;
      debugPrint("Listening for desktop broadcasts on UDP port 9092...");

      _discoverySocket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = _discoverySocket!.receive();
          if (datagram != null) {
            try {
              final message = utf8.decode(datagram.data);
              final payload = jsonDecode(message);
              
              if (payload["service"] == "AIRMIC") {
                final code = payload["code"]?.toString() ?? "";
                final ip = payload["ip"]?.toString() ?? datagram.address.address;
                final port = int.tryParse(payload["control_port"]?.toString() ?? "9090") ?? 9090;
                final deviceName = payload["device_name"]?.toString() ?? "Windows-PC";

                final host = DiscoveredHost(
                  ip: ip,
                  port: port,
                  deviceName: deviceName,
                  code: code,
                  lastSeen: DateTime.now(),
                );

                setState(() {
                  _discoveredHosts[code] = host;
                });
              }
            } catch (e) {
              debugPrint("Failed to parse discovery payload: $e");
            }
          }
        }
      });

      // Periodically clean up offline hosts (older than 6 seconds)
      _discoveryCleanupTimer = Timer.periodic(const Duration(seconds: 4), (timer) {
        final now = DateTime.now();
        final expiredCodes = <String>[];
        
        _discoveredHosts.forEach((code, host) {
          if (now.difference(host.lastSeen).inSeconds > 6) {
            expiredCodes.add(code);
          }
        });

        if (expiredCodes.isNotEmpty) {
          setState(() {
            for (var c in expiredCodes) {
              _discoveredHosts.remove(c);
            }
          });
        }
      });
    } catch (e) {
      debugPrint("Failed to bind discovery socket: $e");
    }
  }

  void _connectWithCode() {
    final code = _otpController.text.trim();
    if (code.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter a valid 6-digit pairing code")),
      );
      return;
    }

    final host = _discoveredHosts[code];
    if (host == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("No computer found matching code $code. Make sure the desktop app is open and on the same network.")),
      );
      return;
    }

    _connectToHost(host);
  }

  void _connectToHost(DiscoveredHost host) async {
    setState(() {
      _status = ConnectionStatus.connecting;
      _activePcIp = host.ip;
    });

    try {
      final socket = await Socket.connect(host.ip, host.port, timeout: const Duration(seconds: 4));
      _socket = socket;

      // Pre-populate input device list for the mic selector dropdown
      try {
        final devices = await _audioRecorder.listInputDevices();
        _previousDeviceIds = devices.map((d) => d.id).toSet();
        final best = _selectBestDevice(devices);
        if (mounted) {
          setState(() {
            _availableInputDevices = devices;
            _activeInputDevice = best;
            _selectedMicDevice = best;
          });
        }
      } catch (_) {}

      final paired = _pairedDevices[host.deviceName];
      if (paired != null) {
        // Send pairing identifier for bypass
        socket.write("HELLO_AIRMIC ${paired.pairingIdentifier}\n");
      } else {
        // Send active pairing code
        socket.write("HELLO_AIRMIC ${host.code}\n");
      }

      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          final cleanLine = line.trim();
          debugPrint("Received from server: $cleanLine");
          
          if (cleanLine.startsWith("WELCOME_AIRMIC")) {
            final parts = cleanLine.split(' ');
            if (parts.length >= 2) {
              // New pairing successful: store the generated ID
              final pairingId = parts[1].trim();
              final device = PairedDevice(
                deviceName: host.deviceName,
                lastKnownIp: host.ip,
                pairingIdentifier: pairingId,
              );
              setState(() {
                _pairedDevices[host.deviceName] = device;
              });
              _savePairedDevices();
              debugPrint("Saved new pairing config for device: ${host.deviceName}");
            } else {
              // Existing pairing bypass successful: update last known IP
              final existing = _pairedDevices[host.deviceName];
              if (existing != null) {
                final device = PairedDevice(
                  deviceName: host.deviceName,
                  lastKnownIp: host.ip,
                  pairingIdentifier: existing.pairingIdentifier,
                );
                setState(() {
                  _pairedDevices[host.deviceName] = device;
                });
                _savePairedDevices();
              }
            }

            _otpController.clear();
            setState(() {
              _status = ConnectionStatus.connected;
            });
            _sendMetadata();
            _initSpeakerPlayback();

            // Start device monitor timer
            _deviceMonitorTimer?.cancel();
            _deviceMonitorTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
              _refreshDevices();
            });
          } else if (cleanLine == "REJECTED") {
            debugPrint("Connection rejected by server.");
            _disconnect();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Pairing rejected. The code may have expired or changed.")),
              );
            }
          }
        },
        onError: (err) {
          debugPrint("Socket error: $err");
          _disconnect();
        },
        onDone: () {
          debugPrint("Socket closed by remote peer.");
          _disconnect();
        },
      );
    } catch (e) {
      debugPrint("Connection failed: $e");
      setState(() {
        _status = ConnectionStatus.failed;
      });
    }
  }

  Future<void> _enableBluetoothSco(bool enable) async {
    try {
      if (Platform.isAndroid) {
        if (enable) {
          final res = await _bluetoothChannel.invokeMethod("startBluetoothSco");
          debugPrint("Native startBluetoothSco returned: $res");
        } else {
          final res = await _bluetoothChannel.invokeMethod("stopBluetoothSco");
          debugPrint("Native stopBluetoothSco returned: $res");
        }
      }
    } catch (e) {
      debugPrint("Failed to toggle Bluetooth SCO: $e");
    }
  }

  void _sendMetadata() {
    if (_socket == null) return;
    
    final metadata = {
      "deviceModel": _deviceModel,
      "androidVersion": _androidVersion,
      "capabilities": {
        "microphone": true,
        "camera": true,
        "speaker": true,
      }
    };
    
    _socket!.write("${jsonEncode(metadata)}\n");
    debugPrint("Sent metadata payload to server.");
  }

  IconData _deviceIcon(InputDeviceType? type) {
    switch (type) {
      case InputDeviceType.bluetoothSco:
      case InputDeviceType.bluetoothA2dp:
      case InputDeviceType.bluetoothLe:
        return Icons.bluetooth_rounded;
      case InputDeviceType.usb:
        return Icons.usb_rounded;
      case InputDeviceType.wiredHeadset:
        return Icons.headset_rounded;
      case InputDeviceType.builtIn:
        return Icons.phone_android_rounded;
      default:
        return Icons.mic_rounded;
    }
  }

  // Heuristic to select the most appropriate microphone (prioritizing wireless/external)
  InputDevice? _selectBestDevice(List<InputDevice> devices) {
    if (devices.isEmpty) return null;

    // Log all discovered audio devices
    for (var d in devices) {
      debugPrint("Discovered Audio Device: ID='${d.id}', Label='${d.label}', Type='${d.type}'");
    }

    // Prioritize Bluetooth headsets
    for (var dev in devices) {
      if (dev.type == InputDeviceType.bluetoothSco ||
          dev.type == InputDeviceType.bluetoothLe ||
          dev.type == InputDeviceType.bluetoothA2dp) {
        debugPrint("Selecting Bluetooth Input Device: '${dev.label}'");
        return dev;
      }
    }

    // Prioritize Wired/USB Headsets
    for (var dev in devices) {
      if (dev.type == InputDeviceType.wiredHeadset ||
          dev.type == InputDeviceType.usb) {
        debugPrint("Selecting Wired/USB Input Device: '${dev.label}'");
        return dev;
      }
    }

    // Prioritize Built-in Mic
    for (var dev in devices) {
      if (dev.type == InputDeviceType.builtIn) {
        debugPrint("Selecting Built-in Input Device: '${dev.label}'");
        return dev;
      }
    }

    // Fallback: first available
    debugPrint("Fallback: Selecting first available microphone");
    return devices.first;
  }

  Future<void> _startStreaming() async {
    final hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Microphone permission denied")),
        );
      }
      return;
    }

    try {
      // Enable foreground background service
      try {
        await FlutterBackground.enableBackgroundExecution();
        debugPrint("Background execution enabled successfully.");
      } catch (bgError) {
        debugPrint("Could not enable background execution: $bgError");
      }

      // Ensure device info (phone model name) is fully loaded to prevent filter race condition
      int retries = 0;
      while (_deviceModel == "Android Device" && retries < 15) {
        await Future.delayed(const Duration(milliseconds: 100));
        retries++;
      }

      // Query initial connected devices and populate selector
      List<InputDevice> devices = [];
      try {
        devices = await _audioRecorder.listInputDevices();
        _previousDeviceIds = devices.map((d) => d.id).toSet();
      } catch (e) {
        debugPrint("Failed to query initial audio inputs: $e");
        devices = [];
      }

      // Use user-selected device if still available, otherwise pick best
      if (_selectedMicDevice != null && devices.any((d) => d.id == _selectedMicDevice!.id)) {
        _activeInputDevice = _selectedMicDevice;
      } else {
        _activeInputDevice = _selectBestDevice(devices);
        _selectedMicDevice = _activeInputDevice;
      }

      // Enable Bluetooth SCO if active device is a wireless headset
      final isBluetooth = _activeInputDevice != null && 
                          (_activeInputDevice!.type == InputDeviceType.bluetoothSco ||
                           _activeInputDevice!.type == InputDeviceType.bluetoothLe ||
                           _activeInputDevice!.type == InputDeviceType.bluetoothA2dp);
      
      bool scoConnected = false;
      if (isBluetooth) {
        await _enableBluetoothSco(true);
        scoConnected = await _waitForScoConnection(timeoutSeconds: 3);
        if (!scoConnected) {
          debugPrint("Bluetooth SCO initialization failed, falling back to phone microphone");
          await _enableBluetoothSco(false);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text("Warning: Bluetooth headset microphone connection failed. Falling back to Phone Microphone."),
                backgroundColor: Color(0xFFFF1744),
                duration: Duration(seconds: 4),
              ),
            );
          }
          final phoneMic = devices.firstWhere(
            (d) => d.type == InputDeviceType.builtIn,
            orElse: () => devices.isNotEmpty ? devices.first : _activeInputDevice!,
          );
          _activeInputDevice = phoneMic;
          _selectedMicDevice = phoneMic;
        }
      } else {
        await _enableBluetoothSco(false);
      }

      _packetsSent = 0;
      _currentBitrate = 0.0;
      _lastMicBytes = 0;
      _lastMicStatsTime = null;

      setState(() {
        _isStreaming = true;
        _availableInputDevices = devices;
      });
      await _updateAudioStream();
      debugPrint("Microphone streaming started natively.");
    } catch (e) {
      debugPrint("Failed to start microphone stream: $e");
      _stopStreaming();
    }
  }

  Future<void> _hotSwapMicrophone() async {
    debugPrint("Hot-swapping microphone stream to device: ${_activeInputDevice?.label ?? 'Default'}...");
    
    final isBluetooth = _activeInputDevice != null && 
                        (_activeInputDevice!.type == InputDeviceType.bluetoothSco ||
                         _activeInputDevice!.type == InputDeviceType.bluetoothLe ||
                         _activeInputDevice!.type == InputDeviceType.bluetoothA2dp);
    
    bool scoConnected = false;
    if (isBluetooth) {
      await _enableBluetoothSco(true);
      scoConnected = await _waitForScoConnection(timeoutSeconds: 3);
      if (!scoConnected) {
        debugPrint("Bluetooth SCO initialization failed during hot-swap, falling back to phone microphone");
        await _enableBluetoothSco(false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Warning: Bluetooth headset microphone connection failed during hot-swap. Falling back to Phone Microphone."),
              backgroundColor: Color(0xFFFF1744),
              duration: Duration(seconds: 4),
            ),
          );
        }
        try {
          final currentDevices = await _audioRecorder.listInputDevices();
          final phoneMic = currentDevices.firstWhere(
            (d) => d.type == InputDeviceType.builtIn,
            orElse: () => currentDevices.isNotEmpty ? currentDevices.first : _activeInputDevice!,
          );
          _activeInputDevice = phoneMic;
          _selectedMicDevice = phoneMic;
        } catch (_) {}
      }
    } else {
      await _enableBluetoothSco(false);
    }
    
    // Wait brief interval for device manager to register new default routing
    await Future.delayed(const Duration(milliseconds: 250));
    
    try {
      await _updateAudioStream();
      debugPrint("Microphone stream hot-swapped successfully.");
    } catch (e) {
      debugPrint("Failed to restart capture stream during hot-swap: $e");
      _stopStreaming();
    }
  }

  Future<void> _onMicDeviceSelected(InputDevice? device) async {
    if (device == null || device.id == _selectedMicDevice?.id) return;
    setState(() {
      _selectedMicDevice = device;
      _activeInputDevice = device;
    });
    if (_isStreaming) {
      await _hotSwapMicrophone();
    }
  }

  Future<void> _stopStreaming() async {
    // Disable background service execution
    try {
      if (FlutterBackground.isBackgroundExecutionEnabled) {
        await FlutterBackground.disableBackgroundExecution();
        debugPrint("Background execution disabled successfully.");
      }
    } catch (bgError) {
      debugPrint("Could not disable background execution: $bgError");
    }

    // Terminate SCO routing link
    await _enableBluetoothSco(false);

    _statsTimer?.cancel();
    _statsTimer = null;
    
    setState(() {
      _isStreaming = false;
      _currentBitrate = 0.0;
    });

    await _updateAudioStream();
    debugPrint("Microphone streaming stopped natively.");
  }

  Future<void> _refreshDevices() async {
    if (_status != ConnectionStatus.connected) return;
    try {
      final currentDevices = await _audioRecorder.listInputDevices();
      final currentDeviceIds = currentDevices.map((d) => d.id).toSet();
      
      if (currentDeviceIds.length != _previousDeviceIds.length ||
          !currentDeviceIds.containsAll(_previousDeviceIds)) {
        
        _previousDeviceIds = currentDeviceIds;
        
        // Auto-select best device if user hasn't manually selected one
        final wasManualSelection = _selectedMicDevice != null &&
            currentDevices.any((d) => d.id == _selectedMicDevice!.id);
            
        InputDevice? newActive;
        if (!wasManualSelection) {
          newActive = _selectBestDevice(currentDevices);
        } else {
          newActive = _selectedMicDevice;
        }

        if (mounted) {
          setState(() {
            _availableInputDevices = currentDevices;
            _activeInputDevice = newActive;
            _selectedMicDevice = newActive;
          });
        }
        
        if (_isStreaming) {
          await _hotSwapMicrophone();
        }
      }
    } catch (e) {
      debugPrint("Error refreshing devices: $e");
    }
  }

  Future<bool> _waitForScoConnection({int timeoutSeconds = 3}) async {
    if (_scoState == "connected") return true;
    
    final completer = Completer<bool>();
    Timer? timeoutTimer;
    
    final pollTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (_scoState == "connected") {
        timer.cancel();
        timeoutTimer?.cancel();
        if (!completer.isCompleted) completer.complete(true);
      } else if (_scoState == "error") {
        timer.cancel();
        timeoutTimer?.cancel();
        if (!completer.isCompleted) completer.complete(false);
      }
    });
    
    timeoutTimer = Timer(Duration(seconds: timeoutSeconds), () {
      pollTimer.cancel();
      if (!completer.isCompleted) completer.complete(false);
    });
    
    return completer.future;
  }

  String _getInputDeviceDisplayName() {
    final dev = _activeInputDevice;
    if (dev == null) {
      return "Phone Microphone";
    }
    switch (dev.type) {
      case InputDeviceType.bluetoothSco:
      case InputDeviceType.bluetoothA2dp:
      case InputDeviceType.bluetoothLe:
        return "Bluetooth Headset Microphone";
      case InputDeviceType.wiredHeadset:
      case InputDeviceType.usb:
        return "Wired Headset Microphone";
      case InputDeviceType.builtIn:
        return "Phone Microphone";
      default:
        final label = dev.label.toLowerCase();
        if (label.contains("blue") || label.contains("bts") || label.contains("sco")) {
          return "Bluetooth Headset Microphone";
        }
        if (label.contains("wired") || label.contains("headset") || label.contains("usb") || label.contains("jack")) {
          return "Wired Headset Microphone";
        }
        return "Phone Microphone";
    }
  }

  Future<void> _initSpeakerPlayback() async {
    try {
      _speakerBitrate = 0.0;
      _speakerPackets = 0;
      _lastSpeakerBytes = 0;
      _lastSpeakerStatsTime = null;
      await _updateAudioStream();

      setState(() {
        _isSpeakerPlaying = false;
      });
      debugPrint("Native speaker playback started.");
    } catch (e) {
      debugPrint("Failed to start speaker playback: $e");
    }
  }

  // Called on disconnect to fully tear down speaker playback (socket + AudioTrack)
  Future<void> _stopSpeakerPlayback() async {
    _speakerStatsTimer?.cancel();
    _speakerStatsTimer = null;

    try {
      await _speakerChannel.invokeMethod("stopAudioStream");
    } catch (e) {
      debugPrint("Failed to stop native audio stream: $e");
    }

    setState(() {
      _isSpeakerPlaying = false;
      _speakerBitrate = 0.0;
      _speakerPackets = 0;
    });
    debugPrint("Speaker playback fully stopped.");
  }

  void _disconnect() {
    _stopSpeakerPlayback();
    if (_isStreaming) {
      _stopStreaming();
    }
    _deviceMonitorTimer?.cancel();
    _deviceMonitorTimer = null;
    _previousDeviceIds = {};
    _activeInputDevice = null;
    _selectedMicDevice = null;
    _scoState = "disconnected";
    
    _socket?.destroy();
    _socket = null;
    _activePcIp = "";
    if (mounted) {
      setState(() {
        _status = ConnectionStatus.disconnected;
      });
    }
  }

  Color _getStatusColor() {
    switch (_status) {
      case ConnectionStatus.disconnected:
        return Colors.white54;
      case ConnectionStatus.connecting:
        return const Color(0xFFFF9100);
      case ConnectionStatus.connected:
        return const Color(0xFF00E676);
      case ConnectionStatus.failed:
        return const Color(0xFFFF1744);
    }
  }

  String _getStatusText() {
    switch (_status) {
      case ConnectionStatus.disconnected:
        return "Searching";
      case ConnectionStatus.connecting:
        return "Connecting";
      case ConnectionStatus.connected:
        return "Connected";
      case ConnectionStatus.failed:
        return "Connection Failed";
    }
  }

  @override
  void dispose() {
    _stopSpeakerPlayback();
    if (_isStreaming) {
      _stopStreaming();
    }
    _socket?.destroy();
    _otpController.dispose();
    _discoverySocket?.close();
    _discoveryCleanupTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _status == ConnectionStatus.connected;
    final isConnecting = _status == ConnectionStatus.connecting;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 30),
                // App Logo Header
                Center(
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.02),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Icon(
                          Icons.mic_rounded,
                          size: 48,
                          color: _isStreaming ? const Color(0xFF00E676) : const Color(0xFF00E5FF),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        "AirMic Mobile",
                        style: TextStyle(
                          fontFamily: 'Outfit',
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        "Client Stream Controller",
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white54,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),

                // Status Display
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "Status",
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: Colors.white70,
                          ),
                        ),
                        Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: _getStatusColor(),
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: _getStatusColor().withValues(alpha: 0.4),
                                    blurRadius: 6,
                                    spreadRadius: 2,
                                  )
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              _getStatusText(),
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: _getStatusColor(),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Main Connection and Streaming Views
                if (isConnected) ...[
                  // Streaming Info & Control
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            "Microphone Stream",
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _isStreaming ? "Streaming live audio over UDP port 9091" : "Microphone capture is idle",
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.white54,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              const Text(
                                "Active Input: ",
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.white30,
                                ),
                              ),
                              Text(
                                _getInputDeviceDisplayName(),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF00E5FF),
                                ),
                              ),
                            ],
                          ),
                          if (_availableInputDevices.isNotEmpty) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.white10),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<InputDevice>(
                                  value: _selectedMicDevice,
                                  isExpanded: true,
                                  icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white54),
                                  dropdownColor: const Color(0xFF0F131A),
                                  hint: const Text("Default (System)", style: TextStyle(color: Colors.white38, fontSize: 13)),
                                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                                  items: _availableInputDevices.map((d) {
                                    return DropdownMenuItem<InputDevice>(
                                      value: d,
                                      child: Row(
                                        children: [
                                          Icon(
                                            _deviceIcon(d.type),
                                            size: 16,
                                            color: Colors.white54,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(d.label, overflow: TextOverflow.ellipsis),
                                          ),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                  onChanged: (device) {
                                    _onMicDeviceSelected(device);
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          const SizedBox(height: 8),
                          if (_isStreaming) ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text("Bitrate:", style: TextStyle(color: Colors.white30, fontSize: 14)),
                                Text("${_currentBitrate.toStringAsFixed(1)} kbps", style: const TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold, fontSize: 14)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text("Packets Sent:", style: TextStyle(color: Colors.white30, fontSize: 14)),
                                Text("$_packetsSent", style: const TextStyle(color: Colors.white70, fontSize: 14)),
                              ],
                            ),
                            const SizedBox(height: 20),
                          ],
                          ElevatedButton.icon(
                            onPressed: _isStreaming ? _stopStreaming : _startStreaming,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _isStreaming
                                  ? const Color(0xFFFF1744)
                                  : const Color(0xFF00E676),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 4,
                            ),
                            icon: Icon(_isStreaming ? Icons.stop_rounded : Icons.play_arrow_rounded),
                            label: Text(
                              _isStreaming ? "Stop Microphone" : "Start Microphone",
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton(
                            onPressed: _disconnect,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFFF1744),
                              side: const BorderSide(color: Color(0xFFFF1744)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text("Disconnect", style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Speaker Stream (PC → Phone) Card
                  _SpeakerStreamCard(
                    isPlaying: _isSpeakerPlaying,
                    bitrate: _speakerBitrate,
                    packets: _speakerPackets,
                  ),
                ] else ...[
                    // Connection Configuration
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            "Connect to PC",
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            "Enter the 6-digit code shown on your computer screen to establish a secure connection.",
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.white54,
                            ),
                          ),
                          const SizedBox(height: 20),
                          OtpInputField(
                            controller: _otpController,
                            enabled: !isConnecting,
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton(
                            onPressed: isConnecting ? null : _connectWithCode,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00E5FF),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 4,
                            ),
                            child: Text(
                              isConnecting ? "Connecting..." : "Connect",
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Discovered Hosts Info Block
                  if (_discoveredHosts.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
                      child: Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: Color(0xFF00E676),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            "Discovered ${_discoveredHosts.length} PC(s) on network",
                            style: const TextStyle(fontSize: 12, color: Colors.white30),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // Known Devices List (OTP Bypass)
                  if (_pairedDevices.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const Text(
                      "Known Devices",
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ..._pairedDevices.values.map((device) {
                      final isDiscovered = _discoveredHosts.values.any((h) => h.deviceName == device.deviceName);
                      return Card(
                        child: ListTile(
                          leading: const Icon(Icons.computer_rounded, color: Color(0xFF00E5FF)),
                          title: Text(
                            device.deviceName,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            isDiscovered ? "Detected (Tap to connect)" : "Offline / Not detected",
                            style: TextStyle(
                              color: isDiscovered ? const Color(0xFF00E676) : Colors.white30,
                              fontSize: 12,
                            ),
                          ),
                          trailing: isDiscovered
                              ? const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Color(0xFF00E676))
                              : null,
                          onTap: isDiscovered
                              ? () {
                                  final host = _discoveredHosts.values.firstWhere((h) => h.deviceName == device.deviceName);
                                  _connectToHost(host);
                                }
                              : null,
                        ),
                      );
                    }),
                  ],
                ],
                const SizedBox(height: 40),

                // Device Meta Footer
                Center(
                  child: Column(
                    children: [
                      Text(
                        "Device: $_deviceModel",
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.white70,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "OS Version: Android $_androidVersion",
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white30,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SpeakerStreamCard extends StatelessWidget {
  final bool isPlaying;
  final double bitrate;
  final int packets;

  const _SpeakerStreamCard({
    required this.isPlaying,
    required this.bitrate,
    required this.packets,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: isPlaying
                        ? const Color(0xFF00E676).withValues(alpha: 0.1)
                        : Colors.white.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isPlaying ? Icons.speaker_rounded : Icons.speaker_phone_rounded,
                    color: isPlaying ? const Color(0xFF00E676) : Colors.white38,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "PC Audio (Speaker)",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isPlaying ? "Receiving" : "Waiting",
                        style: TextStyle(
                          fontSize: 12,
                          color: isPlaying ? const Color(0xFF00E676) : Colors.white38,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isPlaying)
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: const Color(0xFF00E676),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF00E676).withValues(alpha: 0.6),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            if (isPlaying) ...[
              const SizedBox(height: 14),
              Container(
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.02),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    _StatItem(label: "Bitrate", value: "${bitrate.toStringAsFixed(1)} kbps", color: const Color(0xFF00E5FF)),
                    _StatItem(label: "Packets", value: "$packets", color: Colors.white70),
                    _StatItem(label: "Latency", value: "<50 ms", color: const Color(0xFF00E676)),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatItem({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              color: Colors.white30,
            ),
          ),
        ],
      ),
    );
  }
}

class OtpInputField extends StatefulWidget {
  final TextEditingController controller;
  final int length;
  final bool enabled;

  const OtpInputField({
    super.key,
    required this.controller,
    this.length = 6,
    this.enabled = true,
  });

  @override
  State<OtpInputField> createState() => _OtpInputFieldState();
}

class _OtpInputFieldState extends State<OtpInputField> {
  final FocusNode _focusNode = FocusNode();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.enabled
          ? () {
              _focusNode.requestFocus();
            }
          : null,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Invisible TextField underneath
          Opacity(
            opacity: 0,
            child: SizedBox(
              width: double.infinity,
              height: 56,
              child: TextField(
                controller: widget.controller,
                focusNode: _focusNode,
                enabled: widget.enabled,
                keyboardType: TextInputType.number,
                maxLength: widget.length,
                decoration: const InputDecoration(
                  counterText: "",
                ),
              ),
            ),
          ),
          // 6 Beautiful boxes on top
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(widget.length, (index) {
              final text = widget.controller.text;
              final char = text.length > index ? text[index] : "";
              final isFocused = _focusNode.hasFocus && text.length == index;

              return Container(
                width: 42,
                height: 54,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.03),
                  border: Border.all(
                    color: isFocused
                        ? const Color(0xFF00E5FF)
                        : (char.isNotEmpty ? const Color(0xFF00E676) : Colors.white12),
                    width: isFocused ? 2 : 1,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Text(
                  char,
                  style: const TextStyle(
                    fontFamily: 'Outfit',
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF00E5FF),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}
