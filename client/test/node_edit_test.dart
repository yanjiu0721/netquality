import 'package:flutter_test/flutter_test.dart';
import 'package:netquality/models/node_edit.dart';
import 'package:netquality/models/port_field.dart';
import 'package:netquality/models/probe_profile.dart';
import 'package:netquality/models/session_config.dart';
import 'package:netquality/storage/token_vault.dart';

void main() {
  test(
    'editing keeps the node id and replaces only a non-blank token',
    () async {
      const original = RemoteNode(
        id: 'node-7',
        name: '机房',
        baseUrl: 'https://probe.example:8443',
        visibility: 'private',
      );
      final renamed = applyNodeEdit(
        original,
        name: '机房乙',
        baseUrl: 'https://probe.example:8443',
      );
      expect(renamed.id, 'node-7');
      expect(renamed.name, '机房乙');
      expect(renamed.visibility, 'private');

      final moved = applyNodeEdit(
        renamed,
        name: '机房乙',
        baseUrl: 'https://other.example:8443',
      );
      expect(moved.id, 'node-7');
      expect(moved.visibility, '');

      final vault = MemoryTokenVault();
      await vault.write(nodeTokenKey('node-7'), 'saved-secret');
      expect(await saveEditedNodeToken(vault, 'node-7', '   '), isFalse);
      expect(await vault.read(nodeTokenKey('node-7')), 'saved-secret');
      expect(replacementNodeToken('   '), isNull);
      expect(
        await saveEditedNodeToken(vault, 'node-7', ' next-secret '),
        isTrue,
      );
      expect(await vault.read(nodeTokenKey('node-7')), 'next-secret');
      final encoded = moved.toJson();
      expect(encoded.containsKey('token'), isFalse);
      expect(encoded.values, isNot(contains('saved-secret')));
      expect(encoded.values, isNot(contains('next-secret')));
    },
  );

  test(
    'port follows the profile default unless the user typed another port',
    () {
      expect(ProbeProfile.nqTcp.port, 19090);
      expect(ProbeProfile.nqUdp.port, 19091);
      expect(portHint(ProbeProfile.nqTcp), '合作反射 TCP 默认 19090');
      expect(portHint(ProbeProfile.nqUdp), '合作反射 UDP 默认 19091');
      expect(
        portAfterProfileChange(
          current: '19090',
          previousDefault: 19090,
          nextDefault: 19091,
        ),
        '19091',
      );
      expect(
        portAfterProfileChange(
          current: ' 19090 ',
          previousDefault: 19090,
          nextDefault: 19132,
        ),
        '19132',
      );
      expect(
        portAfterProfileChange(
          current: '',
          previousDefault: 19090,
          nextDefault: 19091,
        ),
        '19091',
      );
      expect(
        portAfterProfileChange(
          current: '25565',
          previousDefault: 19090,
          nextDefault: 19091,
        ),
        '25565',
      );
      expect(
        portAfterProfileChange(
          current: '25565',
          previousDefault: 19091,
          nextDefault: 80,
        ),
        '25565',
      );
    },
  );
}
