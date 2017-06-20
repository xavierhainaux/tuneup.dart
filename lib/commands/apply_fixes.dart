// Copyright (c) 2014, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

import 'dart:async';

import 'dart:io';
import 'package:analysis_server_lib/analysis_server_lib.dart';
import 'package:cli_util/cli_logging.dart';
import 'package:path/path.dart' as path;

import '../src/common.dart';
import '../tuneup.dart';

class ApplyFixesCommand extends TuneupCommand {
  ApplyFixesCommand(Tuneup tuneup)
      : super(tuneup, 'apply-fixes',
            'apply all the available fixes to fix the warnings');

  Future execute(Project project, [args]) async {
    Progress progress =
        project.logger.progress('Applying quick fixes on ${project.name}');

    // init
    AnalysisServer client = await AnalysisServer.create(
      sdkPath: project.sdkPath,
      clientId: appName,
      clientVersion: appVersion,
    );

    Completer completer = new Completer();
    client.processCompleter.future.then((int code) {
      if (!completer.isCompleted) {
        completer.completeError('analysis exited early (exit code $code)');
      }
    });

    await client.server.onConnected.first.timeout(new Duration(seconds: 10));

    // handle errors
    client.server.onError.listen((ServerError e) {
      StackTrace trace =
          e.stackTrace == null ? null : new StackTrace.fromString(e.stackTrace);
      completer.completeError(e, trace);
    });

    client.server.setSubscriptions(['STATUS']);

    Map<String, List<AnalysisError>> errorMap = new Map();
    client.analysis.onErrors.listen((AnalysisErrors e) {
      errorMap[e.file] = e.errors;
    });

    String analysisRoot = path.canonicalize(project.dir.absolute.path);
    client.analysis.setAnalysisRoots([analysisRoot], []);

    Stream onStatus = client.server.onStatus;

    fixAll() async {
      while (true) {
        errorMap = {};

        // We wait for at least a isAnalyzing: true followed for isAnalyzing: false
        await onStatus.where((s) => s.analysis?.isAnalyzing == true).first;
        await onStatus.where((s) => !s.analysis.isAnalyzing).first;

        List<AnalysisError> errors =
            errorMap.values.expand((e) => e).where((e) => e.hasFix).toList();

        if (errors.isEmpty) break;

        AnalysisError e = errors.first;

        var fixes =
            await client.edit.getFixes(e.location.file, e.location.offset);
        AnalysisErrorFixes fix = fixes.fixes.first;

        SourceChange sourceChange = fix.fixes.first;
        for (SourceFileEdit fileEdit in sourceChange.edits) {
          File file = new File(fileEdit.file);
          String content = file.readAsStringSync();
          List<SourceEdit> sortedEdits = fileEdit.edits.toList();
          sortedEdits.sort((e1, e2) => e2.offset.compareTo(e1.offset));
          for (SourceEdit edit in sortedEdits) {
            content = content.replaceRange(
                edit.offset, edit.offset + edit.length, edit.replacement);
          }

          project.print(
              'Apply fix: ${sourceChange.message} (${e.code}) on ${sourceChange
          .edits.first.file}');
          file.writeAsStringSync(content);
        }
      }
      if (!completer.isCompleted) {
        completer.complete();
      }
    }

    fixAll();

    // wait for finish
    try {
      await completer.future;
    } catch (error, st) {
      progress.cancel();

      project.logger.stderr('${error}');
      project.logger.stderr('${st}');

      return new ExitCode(1);
    } finally {
      client.dispose();
      progress.finish();
    }
  }
}
