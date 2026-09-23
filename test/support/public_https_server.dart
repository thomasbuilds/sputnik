import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A public address the SSRF guard lets through. It is never contacted:
/// [PublicHttpsServer.run] sends every connection to a loopback server.
const publicTestAddress = '93.184.215.14';

// Self-signed for publicTestAddress only, valid until 2126. Made with:
//   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1
//     -nodes -days 36500 -subj "/CN=sputnik test"
//     -addext "subjectAltName=IP:93.184.215.14"
const _certificate = '''
-----BEGIN CERTIFICATE-----
MIIBlDCCATmgAwIBAgIUXOS2rEHaUrAv7jeDvb9ALgcX5kIwCgYIKoZIzj0EAwIw
FzEVMBMGA1UEAwwMc3B1dG5payB0ZXN0MCAXDTI2MDkyMzA5MTM1MloYDzIxMjYw
ODMwMDkxMzUyWjAXMRUwEwYDVQQDDAxzcHV0bmlrIHRlc3QwWTATBgcqhkjOPQIB
BggqhkjOPQMBBwNCAATGGExyzAHcv3sQc+f0xhBCN76dRhVLXAVqpJU1GFGr+EZ5
80Cb3bKM6Ay6eZT0ao88exOpzH63t+gR2pdceGUio2EwXzAdBgNVHQ4EFgQUtJAr
DK+OO320m3cw3hMERrlaBI8wHwYDVR0jBBgwFoAUtJArDK+OO320m3cw3hMERrla
BI8wDwYDVR0RBAgwBocEXbjXDjAMBgNVHRMBAf8EAjAAMAoGCCqGSM49BAMCA0kA
MEYCIQCp/4EbxYxZAm7ZLSXA8oavXKjydbJWowlqk866crjutwIhALdF1cCOm2Xv
NJzllGrhfZcFOFQR+F5FBcDPpz+mMlRF
-----END CERTIFICATE-----
''';

const _privateKey = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgLK9IQW/zj7qufi+c
syB4OR0+mGwFymkNUdYRP/xbU9OhRANCAATGGExyzAHcv3sQc+f0xhBCN76dRhVL
XAVqpJU1GFGr+EZ580Cb3bKM6Ay6eZT0ao88exOpzH63t+gR2pdceGUi
-----END PRIVATE KEY-----
''';

var _trusted = false;

final class _ToLoopback extends IOOverrides {
  _ToLoopback(this._port, this._targets);

  final int _port;
  final List<String> _targets;

  @override
  Future<ConnectionTask<Socket>> socketStartConnect(
    host,
    int port, {
    sourceAddress,
    int sourcePort = 0,
  }) {
    _targets.add('${host is InternetAddress ? host.address : host}:$port');
    return super.socketStartConnect(InternetAddress.loopbackIPv4, _port);
  }
}

/// A real HTTPS server on loopback, reached as if it were [publicTestAddress],
/// so code that insists on a public address and TLS can be tested offline.
class PublicHttpsServer {
  PublicHttpsServer._(this._server);

  final HttpServer _server;

  /// Where [run] was asked to connect, as `address:port`.
  final connectTargets = <String>[];

  /// Serves [handler]; its certificate is trusted by the default context.
  static Future<PublicHttpsServer> start(
    void Function(HttpRequest request) handler,
  ) async {
    if (!_trusted) {
      SecurityContext.defaultContext.setTrustedCertificatesBytes(
        utf8.encode(_certificate),
      );
      _trusted = true;
    }
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(_certificate))
      ..usePrivateKeyBytes(utf8.encode(_privateKey));
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    server.listen(handler);
    return PublicHttpsServer._(server);
  }

  /// Runs [body] with every outgoing connection sent to this server.
  Future<T> run<T>(Future<T> Function() body) => IOOverrides.runWithIOOverrides(
    body,
    _ToLoopback(_server.port, connectTargets),
  );

  Future<void> close() => _server.close(force: true);
}
