//INFO: Simplified implementation (the full one lives in the private package).
//
// Scores every IPv4 interface and picks the LAN address a trainer app can
// actually reach: private Wi-Fi/Ethernet first, while VPN tunnels (Tailscale,
// ZeroTier, WireGuard…), virtualization bridges (Hyper-V/WSL, VirtualBox,
// VMware, Docker) and link-local addresses go last.

import 'dart:io';

/// How the host's network interfaces are enumerated. Injectable so tests can
/// simulate multi-homed machines without touching the real network stack.
typedef InterfaceLister = Future<List<NetworkInterface>> Function();

/// One scored IPv4 candidate considered by [AdvertisedAddressPicker].
class AddressCandidate {
  final String interfaceName;
  final String address;
  final int score;
  final bool isVirtual;

  const AddressCandidate({
    required this.interfaceName,
    required this.address,
    required this.score,
    required this.isVirtual,
  });
}

/// The picker's decision plus the candidates it weighed — for diagnostics.
class AddressPickReport {
  final InternetAddress? chosen;
  final List<AddressCandidate> candidates;

  const AddressPickReport({required this.chosen, required this.candidates});
}

/// Picks the IPv4 address BikeControl advertises over mDNS.
class AdvertisedAddressPicker {
  AdvertisedAddressPicker._();

  /// Test seam: replace to simulate interface layouts; reset in tearDown.
  static InterfaceLister listInterfaces = _defaultLister;

  static Future<List<NetworkInterface>> _defaultLister() => NetworkInterface.list();

  static final _virtualName = RegExp(
    r'tailscale|zerotier|wireguard|wg\d|tun|tap|utun|ipsec|vpn|nordlynx|hamachi|'
    r'vethernet|hyper-v|wsl|virtualbox|vboxnet|vmware|vmnet|docker|br-|veth|virbr|'
    r'loopback|bluetooth|npcap',
    caseSensitive: false,
  );
  static final _wifiName = RegExp(r'wi-?fi|wlan|wireless', caseSensitive: false);
  static final _lanName =RegExp(r'^(en|eth|wl|wi-?fi|ethernet|lan)', caseSensitive: false);

  static bool _isCgnat(List<int> p) => p[0] == 100 && p[1] >= 64 && p[1] <= 127;
  static bool _isLinkLocal(List<int> p) => p[0] == 169 && p[1] == 254;
  /// VirtualBox host-only (192.168.56.x) or an adapter where this PC is the
  /// gateway (x.x.x.1): not a network the trainer app sits on.
  static bool _looksHostOnly(List<int> p) => (p[0] == 192 && p[1] == 168 && p[2] == 56) || p[3] == 1;
  static bool _isPrivate(List<int> p) =>
      p[0] == 10 || (p[0] == 172 && p[1] >= 16 && p[1] <= 31) || (p[0] == 192 && p[1] == 168);

  static int _score(String interfaceName, InternetAddress address, bool isVirtual) {
    final p = address.rawAddress;
    var score = 0;
    if (_isPrivate(p)) score += 100;
    if (_lanName.hasMatch(interfaceName)) score += 20;
    if (isVirtual) score -= 200;
    if (_isCgnat(p)) score -= 300;
    if (_isLinkLocal(p)) score -= 400;
    // VirtualBox's default host-only network: never the rider's LAN.
    if (p[0] == 192 && p[1] == 168 && p[2] == 56) score -= 150;
    // x.x.x.1 on this PC means it is the gateway of that network — a
    // host-only / Hyper-V / hotspot adapter, not a client on the home LAN.
    if (p[3] == 1) score -= 50;
    // Wi-Fi is the usual home link; a plain "Ethernet N" name is ambiguous
    // (virtual adapters show up as "Ethernet 2/3/5" on Windows).
    if (_wifiName.hasMatch(interfaceName)) score += 10;
    return score;
  }

  /// The address to advertise plus every candidate considered.
  static Future<AddressPickReport> report() async {
    final interfaces = await listInterfaces();
    InternetAddress? best;
    var bestScore = -1 << 30;
    final candidates = <AddressCandidate>[];
    for (final interface in interfaces) {
      final isVirtual = _virtualName.hasMatch(interface.name);
      for (final address in interface.addresses) {
        if (address.type != InternetAddressType.IPv4 || address.isLoopback) continue;
        final score = _score(interface.name, address, isVirtual || _isCgnat(address.rawAddress));
        candidates.add(AddressCandidate(
          interfaceName: interface.name,
          address: address.address,
          score: score,
          isVirtual: isVirtual || _isCgnat(address.rawAddress) || _looksHostOnly(address.rawAddress),
        ));
        if (score > bestScore) {
          bestScore = score;
          best = address;
        }
      }
    }
    candidates.sort((a, b) => b.score.compareTo(a.score));
    return AddressPickReport(chosen: best, candidates: candidates);
  }

  /// The address to advertise, or null when the host has no usable IPv4.
  static Future<InternetAddress?> pick() async => (await report()).chosen;
}
