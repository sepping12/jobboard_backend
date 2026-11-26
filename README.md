# JobBoard – Back-end

Server REST in Dart (shelf). Dati persistenti in `data/db.json`, curriculum in `data/uploads/`.

## Avvio
```
dart pub get
dart run bin/jobboard_backend.dart      # porta 8080 (variabile PORT per cambiarla)
```
Il server ascolta su tutte le interfacce: lo smartphone deve essere sulla stessa rete Wi-Fi del PC
(eventualmente consentire la porta 8080 nel firewall di Windows).

## API
| Metodo | Percorso | Accesso |
|---|---|---|
| POST | /register, /login, /logout | azienda |
| GET | /jobs, /jobs/:id | pubblico |
| POST | /jobs | azienda |
| GET | /my/jobs, /my/jobs/:id/applications | azienda |
| POST | /jobs/:id/applications (multipart: firstName, lastName, email, cv) | pubblico |
| GET | /applications/:id/cv | azienda proprietaria |
