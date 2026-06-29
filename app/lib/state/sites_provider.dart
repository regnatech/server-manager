import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/server.dart';
import '../models/site.dart';
import '../transport/cli_event.dart';
import 'connection_provider.dart';

/// Loads the list of sites by consuming `server --json list` until its
/// terminal sites [DataEvent] arrives.
final sitesProvider = FutureProvider.autoDispose<List<Site>>((ref) async {
  final cli = ref.watch(cliServiceProvider);
  final List<Site> sites = <Site>[];

  await for (final CliEvent e in cli.listSitesEvents()) {
    if (e is DataEvent && e.kind == 'sites') {
      for (final dynamic item in e.items ?? const <dynamic>[]) {
        if (item is Map<String, dynamic>) {
          sites.add(Site.fromJson(item));
        }
      }
    } else if (e is DoneEvent) {
      break;
    }
  }
  return sites;
});

/// Loads the list of configured servers.
final serversProvider = FutureProvider.autoDispose<List<Server>>((ref) async {
  final cli = ref.watch(cliServiceProvider);
  final List<Server> servers = <Server>[];

  await for (final CliEvent e in cli.listServersEvents()) {
    if (e is DataEvent && e.kind == 'servers') {
      for (final dynamic item in e.items ?? const <dynamic>[]) {
        if (item is Map<String, dynamic>) {
          servers.add(Server.fromJson(item));
        }
      }
    } else if (e is DoneEvent) {
      break;
    }
  }
  return servers;
});

/// Selects a single site by domain from the cached [sitesProvider] result.
final siteByDomainProvider =
    Provider.autoDispose.family<Site?, String>((ref, domain) {
  final AsyncValue<List<Site>> sites = ref.watch(sitesProvider);
  return sites.maybeWhen(
    data: (List<Site> list) {
      for (final Site s in list) {
        if (s.domain == domain) return s;
      }
      return null;
    },
    orElse: () => null,
  );
});
