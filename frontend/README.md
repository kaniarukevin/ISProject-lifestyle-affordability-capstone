# Tosha app (Flutter)

The Flutter app for Tosha. The project overview, how to run the app with the backend, and how to deploy it to Netlify are in the [root README](../README.md).

Quick start, with the backend running on port 8000:

```bash
flutter pub get
flutter run -d web-server --web-port 5050 --dart-define=API_URL=http://localhost:8000
flutter test
```
