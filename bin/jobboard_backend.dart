import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_multipart/shelf_multipart.dart';
import 'package:shelf_router/shelf_router.dart';

/// Persistenza: un unico file JSON (data/db.json) + curriculum in data/uploads/.
final _uploadsDir = Directory('data/uploads');
final _dbFile = File('data/db.json');
final _rnd = Random.secure();

late Map<String, dynamic> db;

void loadDb() {
  _uploadsDir.createSync(recursive: true);
  if (_dbFile.existsSync()) {
    db = jsonDecode(_dbFile.readAsStringSync()) as Map<String, dynamic>;
  } else {
    db = {'companies': [], 'jobs': [], 'applications': [], 'sessions': {}};
  }
}

void saveDb() {
  final tmp = File('${_dbFile.path}.tmp');
  tmp.writeAsStringSync(jsonEncode(db));
  tmp.renameSync(_dbFile.path);
}

String randomHex(int bytes) =>
    List.generate(bytes, (_) => _rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

String hashPassword(String password, String salt) =>
    sha256.convert(utf8.encode('$salt:$password')).toString();

Response jsonResp(Object body, {int status = 200}) => Response(
      status,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Response err(int status, String message) => jsonResp({'error': message}, status: status);

Future<Map<String, dynamic>?> readJson(Request req) async {
  try {
    final m = jsonDecode(await req.readAsString());
    return m is Map<String, dynamic> ? m : null;
  } catch (_) {
    return null;
  }
}

/// Restituisce l'azienda autenticata (token nell'header Authorization o ?token=).
Map<String, dynamic>? authCompany(Request req) {
  final h = req.headers['authorization'];
  final token = (h != null && h.startsWith('Bearer '))
      ? h.substring(7)
      : req.url.queryParameters['token'];
  if (token == null) return null;
  final cid = (db['sessions'] as Map)[token];
  if (cid == null) return null;
  for (final c in db['companies'] as List) {
    if (c['id'] == cid) return c as Map<String, dynamic>;
  }
  return null;
}

Map<String, dynamic> publicJob(Map<String, dynamic> j) {
  final company = (db['companies'] as List).firstWhere((c) => c['id'] == j['companyId'], orElse: () => {'name': '?'});
  return {...j, 'companyName': company['name']};
}

final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

Router buildRouter() {
  final r = Router();

  r.get('/health', (Request req) => jsonResp({'ok': true}));

  // R1 - registrazione azienda
  r.post('/register', (Request req) async {
    final b = await readJson(req);
    final name = (b?['name'] ?? '').toString().trim();
    final email = (b?['email'] ?? '').toString().trim().toLowerCase();
    final password = (b?['password'] ?? '').toString();
    if (name.isEmpty || !_emailRe.hasMatch(email) || password.length < 6) {
      return err(400, 'Dati non validi (nome, email valida, password di almeno 6 caratteri)');
    }
    if ((db['companies'] as List).any((c) => c['email'] == email)) {
      return err(409, 'Esiste già un account con questa email');
    }
    final salt = randomHex(8);
    (db['companies'] as List).add({
      'id': randomHex(8),
      'name': name,
      'email': email,
      'salt': salt,
      'passwordHash': hashPassword(password, salt),
    });
    saveDb();
    return jsonResp({'ok': true}, status: 201);
  });

  // R2 - login azienda
  r.post('/login', (Request req) async {
    final b = await readJson(req);
    final email = (b?['email'] ?? '').toString().trim().toLowerCase();
    final password = (b?['password'] ?? '').toString();
    for (final c in db['companies'] as List) {
      if (c['email'] == email && c['passwordHash'] == hashPassword(password, c['salt'])) {
        final token = randomHex(24);
        (db['sessions'] as Map)[token] = c['id'];
        saveDb();
        return jsonResp({'token': token, 'company': {'id': c['id'], 'name': c['name'], 'email': c['email']}});
      }
    }
    return err(401, 'Email o password errate');
  });

  // R3 - logout azienda
  r.post('/logout', (Request req) {
    final h = req.headers['authorization'];
    if (h != null && h.startsWith('Bearer ')) {
      (db['sessions'] as Map).remove(h.substring(7));
      saveDb();
    }
    return jsonResp({'ok': true});
  });

  // R5 - bacheca pubblica
  r.get('/jobs', (Request req) {
    final jobs = (db['jobs'] as List).cast<Map<String, dynamic>>().reversed.map(publicJob).toList();
    return jsonResp(jobs);
  });

  r.get('/jobs/<id>', (Request req, String id) {
    for (final j in db['jobs'] as List) {
      if (j['id'] == id) return jsonResp(publicJob(j as Map<String, dynamic>));
    }
    return err(404, 'Annuncio non trovato');
  });

  // R4 - pubblicazione annuncio
  r.post('/jobs', (Request req) async {
    final c = authCompany(req);
    if (c == null) return err(401, 'Non autenticato');
    final b = await readJson(req);
    final title = (b?['title'] ?? '').toString().trim();
    final description = (b?['description'] ?? '').toString().trim();
    if (title.isEmpty || description.isEmpty) return err(400, 'Titolo e descrizione obbligatori');
    final job = {
      'id': randomHex(8),
      'companyId': c['id'],
      'title': title,
      'description': description,
      'location': (b?['location'] ?? '').toString().trim(),
      'createdAt': DateTime.now().toIso8601String(),
    };
    (db['jobs'] as List).add(job);
    saveDb();
    return jsonResp(publicJob(job), status: 201);
  });

  // R7 - annunci dell'azienda
  r.get('/my/jobs', (Request req) {
    final c = authCompany(req);
    if (c == null) return err(401, 'Non autenticato');
    final apps = db['applications'] as List;
    final jobs = (db['jobs'] as List)
        .cast<Map<String, dynamic>>()
        .where((j) => j['companyId'] == c['id'])
        .map((j) => {...publicJob(j), 'applicationsCount': apps.where((a) => a['jobId'] == j['id']).length})
        .toList()
        .reversed
        .toList();
    return jsonResp(jobs);
  });

  r.get('/my/jobs/<id>/applications', (Request req, String id) {
    final c = authCompany(req);
    if (c == null) return err(401, 'Non autenticato');
    final owns = (db['jobs'] as List).any((j) => j['id'] == id && j['companyId'] == c['id']);
    if (!owns) return err(404, 'Annuncio non trovato');
    final list = (db['applications'] as List).where((a) => a['jobId'] == id).toList().reversed.toList();
    return jsonResp(list);
  });

  // R6 - candidatura (multipart: firstName, lastName, email, cv)
  r.post('/jobs/<id>/applications', (Request req, String id) async {
    final job = (db['jobs'] as List).cast<Map<String, dynamic>>().where((j) => j['id'] == id).firstOrNull;
    if (job == null) return err(404, 'Annuncio non trovato');
    final mp = req.multipart();
    if (mp == null) return err(400, 'Richiesta multipart attesa');

    final fields = <String, String>{};
    String? cvFile;
    String? cvName;
    final appId = randomHex(8);
    await for (final part in mp.parts) {
      final disp = part.headers['content-disposition'] ?? '';
      final name = RegExp(r'name="([^"]*)"').firstMatch(disp)?.group(1);
      final filename = RegExp(r'filename="([^"]*)"').firstMatch(disp)?.group(1);
      if (name == 'cv' && filename != null) {
        final safeExt = filename.contains('.') ? filename.split('.').last.replaceAll(RegExp(r'[^A-Za-z0-9]'), '') : 'bin';
        cvFile = '$appId.$safeExt';
        cvName = filename;
        final sink = File('${_uploadsDir.path}/$cvFile').openWrite();
        await part.pipe(sink);
      } else if (name != null) {
        fields[name] = (await part.readString()).trim();
      }
    }
    final email = (fields['email'] ?? '').toLowerCase();
    if ((fields['firstName'] ?? '').isEmpty ||
        (fields['lastName'] ?? '').isEmpty ||
        !_emailRe.hasMatch(email) ||
        cvFile == null) {
      if (cvFile != null) {
        final f = File('${_uploadsDir.path}/$cvFile');
        if (f.existsSync()) f.deleteSync();
      }
      return err(400, 'Nome, cognome, email valida e curriculum sono obbligatori');
    }
    (db['applications'] as List).add({
      'id': appId,
      'jobId': id,
      'firstName': fields['firstName'],
      'lastName': fields['lastName'],
      'email': email,
      'phone': fields['phone'] ?? '',
      'message': fields['message'] ?? '',
      'cvFile': cvFile,
      'cvName': cvName,
      'createdAt': DateTime.now().toIso8601String(),
    });
    saveDb();
    return jsonResp({'ok': true, 'id': appId}, status: 201);
  });

  // R7 - apertura curriculum (solo azienda proprietaria dell'annuncio)
  r.get('/applications/<id>/cv', (Request req, String id) {
    final c = authCompany(req);
    if (c == null) return err(401, 'Non autenticato');
    final app = (db['applications'] as List).cast<Map<String, dynamic>>().where((a) => a['id'] == id).firstOrNull;
    if (app == null) return err(404, 'Candidatura non trovata');
    final owns = (db['jobs'] as List).any((j) => j['id'] == app['jobId'] && j['companyId'] == c['id']);
    if (!owns) return err(404, 'Candidatura non trovata');
    final file = File('${_uploadsDir.path}/${app['cvFile']}');
    if (!file.existsSync()) return err(404, 'File mancante');
    final ext = (app['cvFile'] as String).split('.').last.toLowerCase();
    final mime = {'pdf': 'application/pdf', 'doc': 'application/msword', 'txt': 'text/plain', 'png': 'image/png', 'jpg': 'image/jpeg'}[ext] ??
        'application/octet-stream';
    return Response.ok(file.openRead(), headers: {
      'content-type': mime,
      'content-length': file.lengthSync().toString(),
      'content-disposition': 'inline; filename="${Uri.encodeComponent(app['cvName'] as String)}"',
    });
  });

  return r;
}

void main(List<String> args) async {
  loadDb();
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  final handler = const Pipeline().addMiddleware(logRequests()).addHandler(buildRouter().call);
  // 0.0.0.0: raggiungibile dallo smartphone sulla stessa rete Wi-Fi
  final server = await io.serve(handler, InternetAddress.anyIPv4, port);
  print('JobBoard backend in ascolto su http://0.0.0.0:${server.port}');
}
