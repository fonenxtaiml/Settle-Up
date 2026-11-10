// UIFLOW-R2-05: commits must carry no AI attribution (co-author or session
// trailers, tool advertisements). The owner's commits are authored as
// sushil3125 and nothing else. tool/git-hooks/commit-msg rejects such
// messages, tool/check_commit_messages.sh checks a range before it is
// pushed to dev or main, and tool/squash_merge.sh brings a branch whose
// history has them into dev without carrying them over.
//
// These tests run the scripts with bash against throwaway repositories.
@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final String _root = Directory.current.path;
String _tool(String name) => '$_root/tool/$name';

Future<ProcessResult> _run(String exe, List<String> args, {String? cwd}) =>
    Process.run(
      exe,
      args,
      workingDirectory: cwd,
      environment: const {
        'GIT_AUTHOR_NAME': 'sushil3125',
        'GIT_AUTHOR_EMAIL': 'qa@example.invalid',
        'GIT_COMMITTER_NAME': 'sushil3125',
        'GIT_COMMITTER_EMAIL': 'qa@example.invalid',
        'GIT_CONFIG_GLOBAL': '/dev/null',
        'GIT_CONFIG_NOSYSTEM': '1',
      },
    );

Future<void> _git(Directory repo, List<String> args) async {
  final r = await _run('git', args, cwd: repo.path);
  expect(r.exitCode, 0, reason: 'git ${args.join(' ')}: ${r.stderr}');
}

Future<void> _commit(Directory repo, String file, String message) async {
  File('${repo.path}/$file').writeAsStringSync('$file\n');
  await _git(repo, ['add', file]);
  final m = File('${repo.path}/.msg')..writeAsStringSync(message);
  await _git(repo, ['commit', '-q', '--no-verify', '-F', m.path]);
  m.deleteSync();
}

const _trailers =
    'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n'
    'Claude-Session: https://claude.ai/code/session_0123456789\n';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('commit_policy_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProcessResult> hook(String message) {
    final f = File('${tmp.path}/COMMIT_EDITMSG')..writeAsStringSync(message);
    return _run('bash', [_tool('git-hooks/commit-msg'), f.path]);
  }

  group('UIFLOW-R2-05 commit-msg hook', () {
    test('rejects co-author and session trailers', () async {
      final r = await hook('Fix the thing (X-01)\n\nBody.\n\n$_trailers');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('Co-Authored-By: Claude'));
      expect(r.stderr, contains('Claude-Session:'));
    });

    for (final line in [
      'co-authored-by: claude <noreply@anthropic.com>',
      'Claude-Session: https://claude.ai/code/session_x',
      'Generated with [Claude Code](https://claude.com/claude-code)',
      'Reviewed-by: bot <noreply@anthropic.com>',
    ]) {
      test('rejects "$line"', () async {
        expect((await hook('Subject\n\n$line\n')).exitCode, 1);
      });
    }

    test(
      'accepts a clean message, a human co-author and git comments',
      () async {
        final r = await hook(
          'Describe the advert id in the privacy policy (PLATFORM-R2-03)\n'
          '\n'
          'Nearby devices see a random id that changes every 10 minutes.\n'
          'Co-authored-by: Asha <asha@example.com>\n'
          '# Co-Authored-By: Claude (a git comment line, stripped by git)\n',
        );
        expect(r.exitCode, 0, reason: '${r.stderr}');
      },
    );
  });

  group('UIFLOW-R2-05 history check and squash merge', () {
    late Directory repo;

    setUp(() async {
      repo = Directory('${tmp.path}/repo')..createSync();
      await _git(repo, ['init', '-q', '-b', 'dev']);
      await _commit(repo, 'a.txt', 'Add a\n');
      await _git(repo, ['checkout', '-q', '-b', 'qa/integration']);
      await _commit(repo, 'b.txt', 'Fix b (QA-01)\n\n$_trailers');
      await _commit(repo, 'c.txt', 'Fix c (QA-02)\n');
      await _git(repo, ['checkout', '-q', 'dev']);
    });

    test('check_commit_messages.sh flags the commit with trailers', () async {
      final r = await _run('bash', [
        _tool('check_commit_messages.sh'),
        'dev..qa/integration',
      ], cwd: repo.path);
      expect(r.exitCode, 1);
      expect(r.stdout, contains('Fix b (QA-01)'));
      expect(r.stdout, isNot(contains('Fix c (QA-02)')));
    });

    test('check_commit_messages.sh passes a clean range', () async {
      final r = await _run('bash', [
        _tool('check_commit_messages.sh'),
        'qa/integration~1..qa/integration',
      ], cwd: repo.path);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    });

    test('squash_merge.sh lands the tree with a clean single commit', () async {
      final r = await _run('bash', [
        _tool('squash_merge.sh'),
        'qa/integration',
        'Merge QA fixes',
      ], cwd: repo.path);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');

      final log = await _run('git', [
        'log',
        '--format=%B',
        'HEAD^..HEAD',
      ], cwd: repo.path);
      final message = log.stdout as String;
      expect(message, startsWith('Merge QA fixes\n'));
      expect(message, contains('- Fix b (QA-01)'));
      expect(message, contains('- Fix c (QA-02)'));
      expect(message, isNot(contains('Claude')));
      expect(message, isNot(contains('anthropic')));

      final diff = await _run('git', [
        'diff',
        '--quiet',
        'HEAD',
        'qa/integration',
      ], cwd: repo.path);
      expect(diff.exitCode, 0, reason: 'dev tree differs from the source');

      final check = await _run('bash', [
        _tool('check_commit_messages.sh'),
        'dev~1..dev',
      ], cwd: repo.path);
      expect(check.exitCode, 0, reason: '${check.stdout}');
    });
  });

  test('UIFLOW-R2-05 (round 3): install_git_hooks.sh enables the hook so a '
      'commit with trailers is rejected', () async {
    final repo = Directory('${tmp.path}/hooked')..createSync();
    await _git(repo, ['init', '-q', '-b', 'dev']);
    Directory('${repo.path}/tool/git-hooks').createSync(recursive: true);
    for (final f in [
      'install_git_hooks.sh',
      'commit_message_policy.sh',
      'git-hooks/commit-msg',
    ]) {
      File(_tool(f)).copySync('${repo.path}/tool/$f');
    }
    final install = await _run('bash', [
      'tool/install_git_hooks.sh',
    ], cwd: repo.path);
    expect(install.exitCode, 0, reason: '${install.stdout}${install.stderr}');
    final cfg = await _run('git', [
      'config',
      '--get',
      'core.hooksPath',
    ], cwd: repo.path);
    expect((cfg.stdout as String).trim(), 'tool/git-hooks');

    await _git(repo, ['add', '.']);
    File('${repo.path}/.msg').writeAsStringSync('Add tools\n\n$_trailers');
    final bad = await _run('git', [
      'commit',
      '-q',
      '-F',
      '.msg',
    ], cwd: repo.path);
    expect(bad.exitCode, isNot(0), reason: 'hook let trailers through');
    File('${repo.path}/.msg').writeAsStringSync('Add tools\n');
    final good = await _run('git', [
      'commit',
      '-q',
      '-F',
      '.msg',
    ], cwd: repo.path);
    expect(good.exitCode, 0, reason: '${good.stderr}');
  });

  test('UIFLOW-R2-05 (round 3): CI checks the commits of every pull request '
      'and push into dev and main', () {
    final wf = File('$_root/.github/workflows/commit-messages.yml')
        .readAsStringSync();
    expect(wf, contains('pull_request:'));
    expect(wf, contains('push:'));
    expect(wf, contains('branches: [dev, main]'));
    expect(wf, contains('fetch-depth: 0'));
    expect(wf, contains('tool/check_commit_messages.sh'));
    expect(wf, contains(r'origin/$BASE_REF..$HEAD_SHA'));
    // Untrusted event fields reach the script only through env, never by
    // ${{ }} interpolation inside run.
    final run = wf.substring(wf.indexOf('run: |'));
    expect(run, isNot(contains(r'${{')));
  });

  test('UIFLOW-R2-05: CONTRIBUTING documents the policy and the tools', () {
    final doc = File('$_root/CONTRIBUTING.md').readAsStringSync();
    expect(doc, contains('## Commit messages'));
    expect(doc, contains('git config core.hooksPath tool/git-hooks'));
    expect(doc, contains('tool/check_commit_messages.sh'));
    expect(doc, contains('tool/squash_merge.sh'));
    expect(doc, contains('tool/install_git_hooks.sh'));
    expect(doc, contains('.github/workflows/commit-messages.yml'));
    expect(doc, contains('required status check'));
  });
}
