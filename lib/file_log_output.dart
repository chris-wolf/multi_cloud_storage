import 'dart:io';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

class FileLogOutput extends LogOutput {
  File? file;

  FileLogOutput() {
    _initFile();
  }

  Future<void> _initFile() async {
    final directory = await getApplicationDocumentsDirectory();
    file = File('${directory.path}/app_logs.txt');
  }

  @override
  void output(OutputEvent event) {
    if (file != null) {
      for (var line in event.lines) {
        file!.writeAsStringSync('$line\n', mode: FileMode.append);
      }
    }
  }
}

class MyFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) {
    return true; // Log all events
  }
}

final logger = Logger(
  filter: MyFilter(),
  output: FileLogOutput(),
  printer: PrettyPrinter(
    methodCount: 0,
    errorMethodCount: 5,
    lineLength: 80,
    colors: false,
    printEmojis: true,
    printTime: true,
  ),
);
