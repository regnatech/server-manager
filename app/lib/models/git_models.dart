/// Models for the Git manager tool, matching the `server --json git …`
/// contract: `git log` (commits), `git status` (working tree), and
/// `git branches`.

/// One commit in the `git log` graph.
///
/// `{"hash","short","parents":["<sha>"…],"author","date","relative",
///   "subject","refs":["origin/main","HEAD -> main","tag: v1.2"]}`
class GitCommit {
  const GitCommit({
    required this.hash,
    required this.short,
    required this.parents,
    required this.author,
    required this.date,
    required this.relative,
    required this.subject,
    required this.refs,
  });

  final String hash;
  final String short;
  final List<String> parents;
  final String author;
  final String date;
  final String relative;
  final String subject;
  final List<String> refs;

  /// True when this commit joins two or more parents (a merge commit).
  bool get isMerge => parents.length >= 2;

  factory GitCommit.fromJson(Map<String, dynamic> json) {
    return GitCommit(
      hash: json['hash']?.toString() ?? '',
      short: json['short']?.toString() ?? '',
      parents: _stringList(json['parents']),
      author: json['author']?.toString() ?? '',
      date: json['date']?.toString() ?? '',
      relative: json['relative']?.toString() ?? '',
      subject: json['subject']?.toString() ?? '',
      refs: _stringList(json['refs']),
    );
  }
}

/// Working-tree status from `git status`.
///
/// `{"branch","upstream","ahead","behind","clean","dirty":[…]}`
class GitStatus {
  const GitStatus({
    required this.branch,
    required this.upstream,
    required this.ahead,
    required this.behind,
    required this.clean,
    required this.dirty,
  });

  final String branch;
  final String upstream;
  final int ahead;
  final int behind;
  final bool clean;
  final List<String> dirty;

  factory GitStatus.fromJson(Map<String, dynamic> json) {
    return GitStatus(
      branch: json['branch']?.toString() ?? '',
      upstream: json['upstream']?.toString() ?? '',
      ahead: _toInt(json['ahead']),
      behind: _toInt(json['behind']),
      clean: json['clean'] == true,
      dirty: _stringList(json['dirty']),
    );
  }
}

/// One branch from `git branches`.
///
/// `{"name","current","remote"}`
class GitBranch {
  const GitBranch({
    required this.name,
    required this.current,
    required this.remote,
  });

  final String name;
  final bool current;
  final bool remote;

  factory GitBranch.fromJson(Map<String, dynamic> json) {
    return GitBranch(
      name: json['name']?.toString() ?? '',
      current: json['current'] == true,
      remote: json['remote'] == true,
    );
  }
}

/// One conflicted file from a `git merge` that hit conflicts.
///
/// `{"path","ours","theirs","conflicted"}` — `ours`/`theirs` are the two full
/// file versions; `conflicted` is the working file with `<<<<<<< ======= >>>>>>>`
/// markers.
class GitConflict {
  const GitConflict({
    required this.path,
    required this.ours,
    required this.theirs,
    required this.conflicted,
  });

  final String path;
  final String ours;
  final String theirs;
  final String conflicted;

  factory GitConflict.fromJson(Map<String, dynamic> json) {
    return GitConflict(
      path: json['path']?.toString() ?? '',
      ours: json['ours']?.toString() ?? '',
      theirs: json['theirs']?.toString() ?? '',
      conflicted: json['conflicted']?.toString() ?? '',
    );
  }
}

List<String> _stringList(Object? v) {
  if (v is List) {
    return v.map((Object? e) => e?.toString() ?? '').toList();
  }
  return const <String>[];
}

int _toInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}
