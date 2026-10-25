import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 强制横屏全屏模式
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const VirtualGamepadApp());
}

class VirtualGamepadApp extends StatelessWidget {
  const VirtualGamepadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pro Virtual Gamepad',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121418),
        colorScheme: const ColorScheme.dark(primary: Color(0xFF00E5FF)),
      ),
      home: const GamepadScreen(),
    );
  }
}

/// 可自定义按键的数据模型
class PadWidgetConfig {
  final String id;
  final String label;
  double xRatio; // 相对屏幕宽度比例 (0.0 ~ 1.0)
  double yRatio; // 相对屏幕高度比例 (0.0 ~ 1.0)
  double scale;  // 缩放倍率 (0.5 ~ 2.0)

  PadWidgetConfig({
    required this.id,
    required this.label,
    required this.xRatio,
    required this.yRatio,
    this.scale = 1.0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'xRatio': xRatio,
        'yRatio': yRatio,
        'scale': scale,
      };

  factory PadWidgetConfig.fromJson(Map<String, dynamic> json) => PadWidgetConfig(
        id: json['id'],
        label: json['label'],
        xRatio: (json['xRatio'] as num).toDouble(),
        yRatio: (json['yRatio'] as num).toDouble(),
        scale: (json['scale'] as num).toDouble(),
      );
}

class GamepadScreen extends StatefulWidget {
  const GamepadScreen({super.key});

  @override
  State<GamepadScreen> createState() => _GamepadScreenState();
}

class _GamepadScreenState extends State<GamepadScreen> {
  static const MethodChannel _btChannel = MethodChannel('com.gamepad.hid/bluetooth');

  // --- 状态与模式控制 ---
  bool _isEditLayoutMode = false;       // 是否处于自定义按键位置编辑模式
  bool _isRightStickSwipeMode = true;   // 右摇杆是否为“3D手游随意滑屏控制视角”模式
  bool _isGyroEnabled = true;           // 是否开启陀螺仪体感
  bool _isNativeGyroHidMode = true;     // true: 同时发送原生6轴HID体感 + 右摇杆映射
  bool _iosMappingCompatMode = true;    // iOS 27 增强映射协议兼容开关
  String _btStatus = '未连接 (点击顶部蓝牙图标配对)';
  String? _selectedWidgetId;

  // --- 灵敏度与死区参数 ---
  double _leftStickSensitivity = 1.0;
  double _rightStickSensitivity = 1.2;
  double _swipeViewSensitivity = 1.8;   // 3D手游滑屏视角灵敏度
  double _gyroSensitivity = 1.5;        // 陀螺仪体感灵敏度
  double _stickDeadzone = 0.08;

  // --- 实时输入状态 ---
  final Set<String> _pressedButtons = {};
  Offset _leftStickPos = Offset.zero;   // [-1.0, 1.0]
  Offset _rightStickPos = Offset.zero;  // [-1.0, 1.0]
  Offset _swipeDeltaOutput = Offset.zero;
  Offset _gyroOffset = Offset.zero;

  // 原始陀螺仪角速度 (rad/s)
  double _rawGyroX = 0.0, _rawGyroY = 0.0, _rawGyroZ = 0.0;

  StreamSubscription<GyroscopeEvent>? _gyroSub;
  Timer? _hidReportTimer;
  Timer? _swipeDecayTimer;

  // 默认按键布局配置
  late List<PadWidgetConfig> _layoutConfigs;

  @override
  void initState() {
    super.initState();
    _initDefaultLayout();
    _loadSavedLayout();
    _startGyroscopeListener();
    // 120Hz 高刷报文发送循环 (8ms 间隔)
    _hidReportTimer = Timer.periodic(const Duration(milliseconds: 8), (_) {
      _sendGamepadReport();
    });
  }

  @override
  void dispose() {
    _gyroSub?.cancel();
    _hidReportTimer?.cancel();
    _swipeDecayTimer?.cancel();
    super.dispose();
  }

  void _initDefaultLayout() {
    _layoutConfigs = [
      PadWidgetConfig(id: 'LEFT_STICK', label: '左摇杆', xRatio: 0.16, yRatio: 0.65, scale: 1.1),
      PadWidgetConfig(id: 'RIGHT_STICK', label: '右视角区', xRatio: 0.78, yRatio: 0.65, scale: 1.15),
      PadWidgetConfig(id: 'BTN_A', label: 'A', xRatio: 0.88, yRatio: 0.45, scale: 1.0),
      PadWidgetConfig(id: 'BTN_B', label: 'B', xRatio: 0.94, yRatio: 0.32, scale: 1.0),
      PadWidgetConfig(id: 'BTN_X', label: 'X', xRatio: 0.82, yRatio: 0.32, scale: 1.0),
      PadWidgetConfig(id: 'BTN_Y', label: 'Y', xRatio: 0.88, yRatio: 0.20, scale: 1.0),
      PadWidgetConfig(id: 'BTN_L1', label: 'L1', xRatio: 0.12, yRatio: 0.15, scale: 1.0),
      PadWidgetConfig(id: 'BTN_L2', label: 'L2', xRatio: 0.24, yRatio: 0.15, scale: 1.0),
      PadWidgetConfig(id: 'BTN_R1', label: 'R1', xRatio: 0.88, yRatio: 0.10, scale: 1.0),
      PadWidgetConfig(id: 'BTN_R2', label: 'R2', xRatio: 0.76, yRatio: 0.10, scale: 1.0),
      PadWidgetConfig(id: 'DPAD_UP', label: '↑', xRatio: 0.32, yRatio: 0.45, scale: 0.9),
      PadWidgetConfig(id: 'DPAD_DOWN', label: '↓', xRatio: 0.32, yRatio: 0.72, scale: 0.9),
      PadWidgetConfig(id: 'DPAD_LEFT', label: '←', xRatio: 0.26, yRatio: 0.58, scale: 0.9),
      PadWidgetConfig(id: 'DPAD_RIGHT', label: '→', xRatio: 0.38, yRatio: 0.58, scale: 0.9),
    ];
  }

  Future<void> _loadSavedLayout() async {
    final prefs = await SharedPreferences.getInstance();
    final savedJson = prefs.getString('custom_gamepad_layout_v1');
    if (savedJson != null) {
      final List decoded = jsonDecode(savedJson);
      setState(() {
        _layoutConfigs = decoded.map((e) => PadWidgetConfig.fromJson(e)).toList();
      });
    }
  }

  Future<void> _saveLayout() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_layoutConfigs.map((e) => e.toJson()).toList());
    await prefs.setString('custom_gamepad_layout_v1', encoded);
  }

  /// 启动陀螺仪监听，模拟原生体感并映射至视角微调
  void _startGyroscopeListener() {
    _gyroSub = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval).listen((event) {
      if (!_isGyroEnabled) {
        _gyroOffset = Offset.zero;
        _rawGyroX = _rawGyroY = _rawGyroZ = 0.0;
        return;
      }
      _rawGyroX = event.x;
      _rawGyroY = event.y;
      _rawGyroZ = event.z;

      // 高通死区过滤，消除静止时的零点漂移
      const double gyroDeadzone = 0.03;
      double yawRate = -event.z;   // 横屏握持时 Z 轴对应水平偏航角速度
      double pitchRate = -event.y; // 横屏握持时 Y 轴对应俯仰角速度

      if (yawRate.abs() < gyroDeadzone) yawRate = 0.0;
      if (pitchRate.abs() < gyroDeadzone) pitchRate = 0.0;

      setState(() {
        _gyroOffset = Offset(
          (yawRate * 0.22 * _gyroSensitivity).clamp(-1.0, 1.0),
          (pitchRate * 0.22 * _gyroSensitivity).clamp(-1.0, 1.0),
        );
      });
    });
  }

  /// 摇杆死区与灵敏度曲线计算
  Offset _applySensitivityCurve(Offset rawInput, double sensitivity) {
    double mag = rawInput.distance;
    if (mag <= _stickDeadzone) return Offset.zero;

    double normalizedMag = ((mag - _stickDeadzone) / (1.0 - _stickDeadzone)).clamp(0.0, 1.0);
    double curvedMag = (math.pow(normalizedMag, 1.2) * sensitivity).clamp(0.0, 1.0);

    double angle = math.atan2(rawInput.dy, rawInput.dx);
    return Offset(math.cos(angle) * curvedMag, math.sin(angle) * curvedMag);
  }

  /// 处理右摇杆“3D手游随意滑屏控制视角”的帧差分输入
  void _onRightTouchpadPanUpdate(DragUpdateDetails details) {
    if (_isEditLayoutMode) return;
    // 将像素移动差分 Δx, Δy 转化为瞬时摇杆脉冲
    const double basePixelScale = 18.0;
    double dx = (details.delta.dx / basePixelScale) * _swipeViewSensitivity;
    double dy = (details.delta.dy / basePixelScale) * _swipeViewSensitivity;

    setState(() {
      _swipeDeltaOutput = Offset(
        dx.clamp(-1.0, 1.0),
        dy.clamp(-1.0, 1.0),
      );
    });

    // 若手指停止滑动（无新 PanUpdate 事件），24ms 后自动归零，确保像 3D 手游一样停手即停视角
    _swipeDecayTimer?.cancel();
    _swipeDecayTimer = Timer(const Duration(milliseconds: 24), () {
      if (mounted) {
        setState(() {
          _swipeDeltaOutput = Offset.zero;
        });
      }
    });
  }

  /// 合成最终右摇杆输出（摇杆/滑屏 + 陀螺仪体感叠加）
  Offset get _finalRightOutput {
    Offset baseRight = _isRightStickSwipeMode
        ? _swipeDeltaOutput
        : _applySensitivityCurve(_rightStickPos, _rightStickSensitivity);

    if (!_isGyroEnabled) return baseRight;

    return Offset(
      (baseRight.dx + _gyroOffset.dx).clamp(-1.0, 1.0),
      (baseRight.dy + _gyroOffset.dy).clamp(-1.0, 1.0),
    );
  }

  /// 组装 20 字节复合 HID 报告并通过原生蓝牙/UDP通道发送
  Future<void> _sendGamepadReport() async {
    if (_isEditLayoutMode) return;

    final Offset leftOut = _applySensitivityCurve(_leftStickPos, _leftStickSensitivity);
    final Offset rightOut = _finalRightOutput;

    // 16-bit 按键位掩码
    int buttonMask = 0;
    const buttonOrder = [
      'BTN_A', 'BTN_B', 'BTN_X', 'BTN_Y',
      'BTN_L1', 'BTN_R1', 'BTN_L2', 'BTN_R2',
      'DPAD_UP', 'DPAD_DOWN', 'DPAD_LEFT', 'DPAD_RIGHT'
    ];
    for (int i = 0; i < buttonOrder.length; i++) {
      if (_pressedButtons.contains(buttonOrder[i])) {
        buttonMask |= (1 << i);
      }
    }

    // 构造 20 字节数据包：
    // [0]: Report ID (0x01 标准手柄 / 0x02 iOS 映射兼容复合报文)
    // [1..2]: Buttons bitmask (uint16)
    // [3..6]: LX, LY, RX, RY (int8: -127 ~ 127)
    // [7..12]: Native Gyro X, Y, Z (int16, 用于模拟器/原生体感)
    final ByteData packet = ByteData(20);
    packet.setUint8(0, _iosMappingCompatMode ? 0x02 : 0x01);
    packet.setUint16(1, buttonMask, Endian.little);
    packet.setInt8(3, (leftOut.dx * 127).round().clamp(-127, 127));
    packet.setInt8(4, (leftOut.dy * 127).round().clamp(-127, 127));
    packet.setInt8(5, (rightOut.dx * 127).round().clamp(-127, 127));
    packet.setInt8(6, (rightOut.dy * 127).round().clamp(-127, 127));

    if (_isGyroEnabled && _isNativeGyroHidMode) {
      packet.setInt16(7, (_rawGyroX * 1000 * _gyroSensitivity).round().clamp(-32768, 32767), Endian.little);
      packet.setInt16(9, (_rawGyroY * 1000 * _gyroSensitivity).round().clamp(-32768, 32767), Endian.little);
      packet.setInt16(11, (_rawGyroZ * 1000 * _gyroSensitivity).round().clamp(-32768, 32767), Endian.little);
    }

    try {
      await _btChannel.invokeMethod('sendHidReport', packet.buffer.asUint8List());
    } catch (_) {
      // 未连接蓝牙宿主时静默忽略
    }
  }

  /// 初始化蓝牙 HID 广播连接
  Future<void> _initBluetoothHid() async {
    try {
      final String result = await _btChannel.invokeMethod('startHidProfile', {
        'iosMappingMode': _iosMappingCompatMode,
      });
      setState(() => _btStatus = result);
    } on PlatformException catch (e) {
      setState(() => _btStatus = '蓝牙初始化提示: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final Size screenSize = MediaQuery.of(context).size;
    final Offset rightPreview = _finalRightOutput;

    return Scaffold(
      body: Stack(
        children: [
          // 1. 若开启了“右摇杆3D手游滑屏模式”，右侧半屏底层均可作为无边界自由滑屏视角区
          if (_isRightStickSwipeMode && !_isEditLayoutMode)
            Positioned(
              left: screenSize.width * 0.45,
              top: 56,
              right: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanUpdate: _onRightTouchpadPanUpdate,
                onPanEnd: (_) => setState(() => _swipeDeltaOutput = Offset.zero),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: Colors.cyanAccent.withOpacity(0.15), width: 1),
                    ),
                  ),
                  alignment: Alignment.bottomRight,
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '3D 自由滑屏视角区 (Δx/Δy: ${rightPreview.dx.toStringAsFixed(2)}, ${rightPreview.dy.toStringAsFixed(2)})',
                    style: TextStyle(color: Colors.cyanAccent.withOpacity(0.45), fontSize: 12),
                  ),
                ),
              ),
            ),

          // 2. 渲染所有可自定义位置的虚拟按键与摇杆
          ..._layoutConfigs.map((cfg) => _buildPositionedControl(cfg, screenSize)),

          // 3. 顶部状态与快捷控制栏
          Positioned(
            top: 8,
            left: 16,
            right: 16,
            child: _buildTopToolbar(),
          ),

          // 4. 编辑模式下的按键缩放悬浮条
          if (_isEditLayoutMode && _selectedWidgetId != null)
            Positioned(
              bottom: 16,
              left: screenSize.width * 0.25,
              right: screenSize.width * 0.25,
              child: _buildScaleEditorBar(),
            ),
        ],
      ),
    );
  }

  Widget _buildTopToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.65),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.bluetooth_Connected, color: Colors.cyanAccent, size: 20),
                onPressed: _initBluetoothHid,
                tooltip: '开启蓝牙 HID 广播',
              ),
              Text(_btStatus, style: const TextStyle(fontSize: 12, color: Colors.white70)),
            ],
          ),
          Row(
            children: [
              FilterChip(
                label: Text(_isRightStickSwipeMode ? '右摇杆: 3D手游滑屏' : '右摇杆: 传统回中',
                    style: const TextStyle(fontSize: 11)),
                selected: _isRightStickSwipeMode,
                onSelected: (v) => setState(() => _isRightStickSwipeMode = v),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: Text('陀螺仪体感 (${_gyroSensitivity.toStringAsFixed(1)}x)',
                    style: const TextStyle(fontSize: 11)),
                selected: _isGyroEnabled,
                onSelected: (v) => setState(() => _isGyroEnabled = v),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isEditLayoutMode ? Colors.amber.shade700 : Colors.blueGrey.shade800,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                ),
                icon: Icon(_isEditLayoutMode ? Icons.save : Icons.open_with, size: 15),
                label: Text(_isEditLayoutMode ? '保存布局' : '自定义按键', style: const TextStyle(fontSize: 12)),
                onPressed: () {
                  setState(() => _isEditLayoutMode = !_isEditLayoutMode);
                  if (!_isEditLayoutMode) _saveLayout();
                },
              ),
              IconButton(
                icon: const Icon(Icons.tune, size: 20),
                onPressed: _showSensitivitySettingsSheet,
                tooltip: '灵敏度与 iOS 27 映射设置',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPositionedControl(PadWidgetConfig cfg, Size screenSize) {
    final double baseSize = (cfg.id == 'LEFT_STICK' || cfg.id == 'RIGHT_STICK') ? 135.0 : 58.0;
    final double finalSize = baseSize * cfg.scale;
    final double left = (cfg.xRatio * screenSize.width) - finalSize / 2;
    final double top = (cfg.yRatio * screenSize.height) - finalSize / 2;

    Widget controlChild;
    if (cfg.id == 'LEFT_STICK') {
      controlChild = _buildAnalogStick(
        size: finalSize,
        label: 'L',
        currentNormalized: _leftStickPos,
        onStickChanged: (val) => setState(() => _leftStickPos = val),
      );
    } else if (cfg.id == 'RIGHT_STICK') {
      controlChild = _isRightStickSwipeMode
          ? _buildSwipeTouchpadZone(finalSize)
          : _buildAnalogStick(
              size: finalSize,
              label: 'R',
              currentNormalized: _rightStickPos,
              onStickChanged: (val) => setState(() => _rightStickPos = val),
            );
    } else {
      controlChild = _buildActionButton(cfg.id, cfg.label, finalSize);
    }

    return Positioned(
      left: left.clamp(0.0, screenSize.width - finalSize),
      top: top.clamp(0.0, screenSize.height - finalSize),
      child: _isEditLayoutMode
          ? GestureDetector(
              onTap: () => setState(() => _selectedWidgetId = cfg.id),
              onPanUpdate: (details) {
                setState(() {
                  _selectedWidgetId = cfg.id;
                  cfg.xRatio = ((cfg.xRatio * screenSize.width + details.delta.dx) / screenSize.width)
                      .clamp(0.04, 0.96);
                  cfg.yRatio = ((cfg.yRatio * screenSize.height + details.delta.dy) / screenSize.height)
                      .clamp(0.08, 0.94);
                });
              },
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _selectedWidgetId == cfg.id ? Colors.amberAccent : Colors.redAccent,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: controlChild,
              ),
            )
          : controlChild,
    );
  }

  /// 传统虚拟摇杆组件
  Widget _buildAnalogStick({
    required double size,
    required String label,
    required Offset currentNormalized,
    required ValueChanged<Offset> onStickChanged,
  }) {
    final double radius = size / 2;
    final double knobRadius = size * 0.22;

    return GestureDetector(
      onPanUpdate: _isEditLayoutMode
          ? null
          : (details) {
              final Offset center = Offset(radius, radius);
              final Offset delta = details.localPosition - center;
              final double dist = delta.distance;
              final double maxDist = radius - knobRadius;
              final Offset clamped = dist > maxDist ? (delta / dist) * maxDist : delta;
              onStickChanged(Offset(clamped.dx / maxDist, clamped.dy / maxDist));
            },
      onPanEnd: _isEditLayoutMode ? null : (_) => onStickChanged(Offset.zero),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(0.07),
          border: Border.all(color: Colors.cyanAccent.withOpacity(0.4), width: 2),
        ),
        child: Center(
          child: Transform.translate(
            offset: Offset(
              currentNormalized.dx * (radius - knobRadius),
              currentNormalized.dy * (radius - knobRadius),
            ),
            child: Container(
              width: knobRadius * 2,
              height: knobRadius * 2,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.cyanAccent.withOpacity(0.75),
                boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 6)],
              ),
              alignment: Alignment.center,
              child: Text(label, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ),
    );
  }

  /// 右摇杆切换为“3D手游滑屏模式”时的触控板视觉指示区
  Widget _buildSwipeTouchpadZone(double size) {
    return GestureDetector(
      onPanUpdate: _onRightTouchpadPanUpdate,
      onPanEnd: (_) => setState(() => _swipeDeltaOutput = Offset.zero),
      child: Container(
        width: size * 1.25,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: Colors.cyanAccent.withOpacity(0.08),
          border: Border.all(color: Colors.cyanAccent.withOpacity(0.5), width: 1.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.touch_app, color: Colors.cyanAccent, size: 28),
            const SizedBox(height: 4),
            const Text('3D 滑屏视角触控区', style: TextStyle(fontSize: 11, color: Colors.cyanAccent)),
            Text(
              '陀螺仪补偿: (${_gyroOffset.dx.toStringAsFixed(2)}, ${_gyroOffset.dy.toStringAsFixed(2)})',
              style: const TextStyle(fontSize: 10, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }

  /// 独立虚拟按键组件（支持多点触控按下与释放）
  Widget _buildActionButton(String id, String label, double size) {
    final bool isPressed = _pressedButtons.contains(id);
    return Listener(
      onPointerDown: _isEditLayoutMode ? null : (_) => setState(() => _pressedButtons.add(id)),
      onPointerUp: _isEditLayoutMode ? null : (_) => setState(() => _pressedButtons.remove(id)),
      onPointerCancel: _isEditLayoutMode ? null : (_) => setState(() => _pressedButtons.remove(id)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 50),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isPressed ? Colors.cyanAccent : Colors.white.withOpacity(0.12),
          border: Border.all(color: isPressed ? Colors.white : Colors.white38, width: 2),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: isPressed ? Colors.black : Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: size * 0.32,
          ),
        ),
      ),
    );
  }

  /// 编辑模式下的按键大小缩放控制条
  Widget _buildScaleEditorBar() {
    final cfg = _layoutConfigs.firstWhere((e) => e.id == _selectedWidgetId);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.amberAccent),
      ),
      child: Row(
        children: [
          Text('当前选中: ${cfg.label}', style: const TextStyle(color: Colors.amberAccent, fontSize: 13)),
          Expanded(
            child: Slider(
              value: cfg.scale,
              min: 0.6,
              max: 1.8,
              onChanged: (val) => setState(() => cfg.scale = val),
            ),
          ),
          TextButton(
            onPressed: () {
              setState(() => _initDefaultLayout());
              _saveLayout();
            },
            child: const Text('重置全部', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  /// 灵敏度、死区、陀螺仪体感与 iOS 27 映射配置弹窗
  void _showSensitivitySettingsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1B1F27),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('手柄灵敏度、3D滑屏视角与陀螺仪体感设置',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.cyanAccent)),
                    const Divider(color: Colors.white24),
                    SwitchListTile(
                      title: const Text('iOS 27 复合映射模式 (Gamepad + 触控指针同步映射)'),
                      subtitle: const Text('启用后兼容 iOS 原生辅助触控映射与 MFi 控制器协议'),
                      value: _iosMappingCompatMode,
                      onChanged: (v) {
                        setModalState(() => _iosMappingCompatMode = v);
                        setState(() {});
                      },
                    ),
                    SwitchListTile(
                      title: const Text('右摇杆改为“3D手游随意滑屏控制视角”'),
                      subtitle: const Text('开启后右侧屏幕按滑动速度转视角，停手即停；关闭则为传统回中摇杆'),
                      value: _isRightStickSwipeMode,
                      onChanged: (v) {
                        setModalState(() => _isRightStickSwipeMode = v);
                        setState(() {});
                      },
                    ),
                    _buildSliderRow('左摇杆灵敏度', _leftStickSensitivity, 0.2, 2.5, (v) {
                      setModalState(() => _leftStickSensitivity = v);
                      setState(() {});
                    }),
                    _buildSliderRow('右摇杆(传统模式)灵敏度', _rightStickSensitivity, 0.2, 2.5, (v) {
                      setModalState(() => _rightStickSensitivity = v);
                      setState(() {});
                    }),
                    _buildSliderRow('右摇杆(3D手游滑屏视角)灵敏度', _swipeViewSensitivity, 0.4, 3.5, (v) {
                      setModalState(() => _swipeViewSensitivity = v);
                      setState(() {});
                    }),
                    _buildSliderRow('陀螺仪原生体感灵敏度', _gyroSensitivity, 0.1, 3.0, (v) {
                      setModalState(() => _gyroSensitivity = v);
                      setState(() {});
                    }),
                    _buildSliderRow('摇杆中心死区 (Deadzone)', _stickDeadzone, 0.0, 0.30, (v) {
                      setModalState(() => _stickDeadzone = v);
                      setState(() {});
                    }),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSliderRow(
      String title, double value, double min, double max, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 210, child: Text('$title (${value.toStringAsFixed(2)})', style: const TextStyle(fontSize: 13))),
        Expanded(
          child: Slider(value: value, min: min, max: max, onChanged: onChanged),
        ),
      ],
    );
  }
}
