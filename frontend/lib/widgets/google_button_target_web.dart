import 'package:flutter/material.dart';
import 'package:google_sign_in_web/web_only.dart' as web;

/// Google requires its own rendered button on the web; it is what starts the sign-in.
Widget googleSignInButton() => web.renderButton();
