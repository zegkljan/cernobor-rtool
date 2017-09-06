import 'dart:math';
import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:location/location.dart';
import 'messages.dart';
import 'settings.dart';

void main() {
  runApp(new RToolApp());
}

class RToolApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return new MaterialApp(
      title: "RTool",
      home: new MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  @override
  State createState() => new MainScreenState();
}

class MainScreenState extends State<MainScreen> {
  static const STATUS_BROADCAST_TIMEOUT = const Duration(seconds: 5);

  final TextEditingController _managerHostController = new TextEditingController();
  final TextEditingController _managerPortController = new TextEditingController();
  final TextEditingController _toolIdController = new TextEditingController();
  final ScrollController _messagesScrollController = new ScrollController();

  Settings _settings = new Settings("192.168.1.6", 6644, 0, 100);

  final int _bufferSize = 500;
  List<Text> _messages = <Text>[];
  int _startIndex = 0;

  static const MethodChannel platform = const MethodChannel("cernobor");
  bool vibrating = false;
  bool sounding = false;

  bool _running = false;
  Socket _socket;
  Location _location = new Location();
  Timer _statusTimer;


  MainScreenState() {
    _settings.load().then((_) {
      setState(() {
        _managerHostController.text = _settings.managerHost;
        _managerPortController.text = _settings.managerPort.toString();
        _toolIdController.text = _settings.toolId.toString();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final double statusBarHeight = MediaQuery.of(context).padding.top;
    Scaffold scaffold = new Scaffold(
      appBar: new AppBar(title: new Text("RTool")),
      drawer: new Drawer(
        elevation: 16.0,
        child: new ListView(
          padding: new EdgeInsets.only(top: statusBarHeight),
          children: <Widget>[
            new ListTile(
              leading: new Icon(Icons.settings),
              title: new Text("Settings"),
              onTap: null,
            ),
            new TextFormField(
              controller: _managerHostController,
              decoration: new InputDecoration.collapsed(
                  hintText: "server hostname"
              ),
              autocorrect: false,
              onSaved: (String val) {
                _settings.managerHost = val;
                _settings.save();
              },
            ),
            new TextFormField(
              controller: _managerPortController,
              decoration: new InputDecoration.collapsed(
                  hintText: "server port"
              ),
              inputFormatters: [
                WhitelistingTextInputFormatter.digitsOnly
              ],
              keyboardType: TextInputType.number,
              autocorrect: false,
              validator: (String s) {
                int val = int.parse(s, onError: (_) => -1);
                if (val < 1 || val > 65535) {
                  return "Not a valid integer between 1 and 65535";
                }
                return null;
              },
              onSaved: (String val) {
                _settings.managerPort = int.parse(val);
                _settings.save();
              },
            ),
            new TextFormField(
              controller: _toolIdController,
              decoration: new InputDecoration.collapsed(
                  hintText: "tool ID"
              ),
              inputFormatters: [
                WhitelistingTextInputFormatter.digitsOnly
              ],
              keyboardType: TextInputType.number,
              autocorrect: false,
              validator: (String s) {
                int val = int.parse(s, onError: (_) => -1);
                if (val < 0 || val > 255) {
                  return "Not a valid integer between 0 and 255";
                }
                return null;
              },
              onSaved: (String val) {
                _settings.toolId = int.parse(val);
                _settings.save();
              },
            ),
            new Text("Range: ${_settings.sensitivityRange} m"),
            new Slider(
              value: _settings.sensitivityRange.toDouble(),
              min: 1.0,
              max: 1000.0,
              activeColor: Theme.of(context).errorColor,
              onChanged: (double val) {
                setState(() {
                  _settings.sensitivityRange = val.round();
                  _settings.save();
                });
              }
            ),
            new ListTile(
              title: new Text(_running ? "Stop" : "Start"),
              onTap: () => _handleStartStop(),
              leading: new Icon(_running ? Icons.pause : Icons.play_arrow),
            ),
            new ListTile(
              title: new Text('start/stop vibration'),
              onTap: () {
                if (vibrating) {
                  _stopVibrate();
                } else {
                  _vibrate(0.8);
                }
                vibrating = !vibrating;
              },
            ),
            new ListTile(
              title: new Text('start/stop sound'),
              onTap: () {
                if (sounding) {
                  _stopSound();
                } else {
                  _playFrequency(6000);
                }
                sounding = !sounding;
              },
            )
          ],
        ),
      ),
      body: new Column(
        children: <Widget>[
          new Row(
            children: <Widget>[
              new RaisedButton(
                onPressed: () => setState(_clearLogMessages),
                color: Theme.of(context).buttonColor,
                child: new Text("Clear output"),
              ),
              new RaisedButton(
                onPressed: _ping,
                color: Theme.of(context).buttonColor,
                child: new Text("Ping"),
              ),
            ],
          ),
          new Divider(height: 1.0, color: Theme.of(context).dividerColor,),
          new Flexible(
            child: new ListView.builder(
              padding: new EdgeInsets.only(bottom: 20.0),
              reverse: false,
              itemBuilder: (_, int index) => _getLogMessage(index),
              itemCount: min(_bufferSize, _messages.length),
              controller: _messagesScrollController,
            )
          )
        ]
      )
    );

    return scaffold;
  }

  void _handleStartStop() {
    _running = !_running;
    setState(() {
      _addLogMessage(_running ? "Started." : "Stopped.");
    });
    if (_running) {
      Socket.connect(_managerHostController.text, 6644).then((socket) {
        setState(() => _addLogMessage("Connected!"));
        _socket = socket;
        _socket.listen((List<int> data) {
          String message = UTF8.decode(data);
          _handleMessage(message);
          setState(() => _addLogMessage(message));
        });
        _statusTimer = new Timer.periodic(STATUS_BROADCAST_TIMEOUT, (_) {
          print("broadcasting status");
          _statusBroadcast();
        });
      });
    } else {
      if (_socket != null) {
        _socket.close();
      }
      _socket = null;
      if (_statusTimer != null) {
        _statusTimer.cancel();
      }
    }
  }

  void _handleMessage(String message) {
    var msg = JSON.decode(message);
    if (IncomingMessage.POWER_SPOT_RSSI.getTypeName() == msg["type"]) {
      double dBm = msg["dBm"];
      double dBmThreshold = msg["dBm-threshold"];
      if (dBm > dBmThreshold) {
        _vibrate((dBm - dBmThreshold) / dBmThreshold);
      } else {
        _stopVibrate();
      }
    }
  }

  String _getId() {
    return _toolIdController.text;
  }

  Future<Null> _playFrequency(int frequency, [int duration]) async {
    Map<String, Object> params = <String, Object>{"frequency": frequency};
    if (duration != null) {
      print("Trying to play $frequency Hz for $duration ms");
      params["duration"] = duration;
    } else {
      print("Trying to play $frequency Hz indefinitely");
    }
    try {
      await platform.invokeMethod("playFrequency", params);
    } on PlatformException catch (e) {
      print(e);
    }
  }

  Future<Null> _stopSound() async {
    print("Stopping sound");
    try {
      await platform.invokeMethod("stopSound");
    } on PlatformException catch (e) {
      print(e);
    }
  }

  Future<Null> _vibrate(double level, [int duration]) async {
    Map<String, Object> params = <String, Object>{"level": level};
    if (duration != null) {
      print("Trying to vibrate for $duration ms");
      params["duration"] = duration;
    } else {
      print("Trying to vibrate for indefinitely");
    }
    try {
      await platform.invokeMethod("vibrate", params);
    } on PlatformException catch (e) {
      print(e);
    }
  }

  Future<Null> _stopVibrate() async {
    print("Stopping vibration");
    try {
      await platform.invokeMethod("stopVibrate");
    } on PlatformException catch (e) {
      print(e);
    }
  }

  void _ping() {
    new PingMessage(_getId()).send(_socket);
  }

  void _statusBroadcast() {
    try {
      _location.getLocation.then((Map<String, double> loc) {
        new StatusBroadcastMessage(_getId(), loc["latitude"], loc["longitude"], _settings.sensitivityRange).send(_socket);
      });
    } catch (exc) {
      print("Status broadcast exc: $exc");
    }
  }

  void _addLogMessage(String msg) {
    msg = new DateTime.now().toString() + ": " + msg;
    if (_messages.length < _bufferSize) {
      _messages.add(new Text(msg));
    } else {
      _messages[_startIndex] = new Text(msg);
      _startIndex = (_startIndex + 1) % _bufferSize;
    }
    _messagesScrollController.jumpTo(_messagesScrollController.position.maxScrollExtent);
  }

  Text _getLogMessage(int index) {
    return _messages[(index + _startIndex) % _bufferSize];
  }

  void _clearLogMessages() {
    _messages.clear();
    _startIndex = 0;
  }
}
