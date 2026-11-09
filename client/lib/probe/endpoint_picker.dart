import 'dart:io';

/// How many misses a working address may have before another address is tried.
const stickyMissThreshold = 3;

const clashFakeIpNote = '这是 VPN 的假地址，只有这个 VPN 开着时才能用';

/// Clash and similar VPNs hand out addresses in 198.18.0.0/15.
bool isClashFakeIp(InternetAddress address) {
  final raw = address.rawAddress;
  if (raw.length != 4) {
    return false;
  }
  return raw[0] == 198 && (raw[1] == 18 || raw[1] == 19);
}

/// Picks which resolved address to send to.
///
/// Before any address has answered, one miss is enough to try the next.
/// After an address has answered, it is kept until [stickyMissThreshold]
/// misses in a row. The list is the one resolved at the start of the run;
/// nothing here looks the name up again.
class EndpointPicker {
  EndpointPicker(this.candidates, {this.stickyMisses = stickyMissThreshold}) {
    if (candidates.isEmpty) {
      throw ArgumentError.value(candidates, 'candidates', 'empty');
    }
  }

  final List<InternetAddress> candidates;
  final int stickyMisses;
  var _index = 0;
  var _misses = 0;
  var _locked = false;

  InternetAddress get current => candidates[_index];

  bool get hasAnswered => _locked;

  /// Records one finished attempt. Returns true when [current] changed.
  bool record(bool gotResponse) {
    if (gotResponse) {
      _locked = true;
      _misses = 0;
      return false;
    }
    _misses += 1;
    final limit = _locked ? stickyMisses : 1;
    if (candidates.length < 2 || _misses < limit) {
      return false;
    }
    _misses = 0;
    _locked = false;
    _index = (_index + 1) % candidates.length;
    return true;
  }
}

Future<List<InternetAddress>> lookupAll(String host) async {
  final parsed = InternetAddress.tryParse(host.trim());
  if (parsed != null) {
    return [parsed];
  }
  final found = await InternetAddress.lookup(host.trim());
  if (found.isEmpty) {
    throw const SocketException('Failed host lookup');
  }
  final seen = <String>{};
  final unique = <InternetAddress>[];
  for (final address in found) {
    if (seen.add('${address.type.name} ${address.address}')) {
      unique.add(address);
    }
  }
  return unique;
}
