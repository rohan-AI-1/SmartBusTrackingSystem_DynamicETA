// lib/screens/registration_screen.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  // Update with your actual server IP
  static const String _backendUrl = "http://10.29.119.181:5000";

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();

  bool _isSendingOtp = false;
  bool _isVerifyingOtp = false;
  bool _isRegistering = false;

  bool _isOtpSent = false;
  bool _isEmailVerified = false;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  // 1. Send OTP
  Future<void> _handleSendOtp() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      _showSnackbar("Please enter a valid email address.", Colors.red);
      return;
    }

    setState(() => _isSendingOtp = true);

    try {
      final response = await http.post(
        Uri.parse('$_backendUrl/api/auth/send-otp'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'email': email}),
      ).timeout(const Duration(seconds: 15));

      final data = json.decode(response.body);

      if (response.statusCode == 200 && data['success'] == true) {
        setState(() {
          _isOtpSent = true;
          _isEmailVerified = false;
        });
        _showSnackbar("Verification code sent to $email", const Color(0xFF2E7D32));
      } else {
        _showSnackbar(data['error'] ?? "Failed to send code.", const Color(0xFFC62828));
      }
    } catch (e) {
      _showSnackbar("Network error: Cannot reach server.", const Color(0xFFC62828));
    } finally {
      if (mounted) setState(() => _isSendingOtp = false);
    }
  }

  // 2. Verify OTP
  Future<void> _handleVerifyOtp() async {
    final email = _emailController.text.trim();
    final otp = _otpController.text.trim();

    if (otp.length < 6) {
      _showSnackbar("Enter the full 6-digit code.", Colors.red);
      return;
    }

    setState(() => _isVerifyingOtp = true);

    try {
      final response = await http.post(
        Uri.parse('$_backendUrl/api/auth/verify-otp'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'email': email, 'otpCode': otp}),
      ).timeout(const Duration(seconds: 10));

      final data = json.decode(response.body);

      if (response.statusCode == 200 && data['success'] == true) {
        setState(() => _isEmailVerified = true);
        _showSnackbar("Email verified successfully!", const Color(0xFF2E7D32));
      } else {
        _showSnackbar(data['error'] ?? "Invalid verification code.", const Color(0xFFC62828));
      }
    } catch (e) {
      _showSnackbar("Network error during verification.", const Color(0xFFC62828));
    } finally {
      if (mounted) setState(() => _isVerifyingOtp = false);
    }
  }

  // 3. Final Register Conductor
  Future<void> _handleRegisterConductor() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();

    if (name.isEmpty) {
      _showSnackbar("Please enter the conductor's name.", Colors.red);
      return;
    }

    if (!_isEmailVerified) {
      _showSnackbar("Please verify the email first.", Colors.red);
      return;
    }

    setState(() => _isRegistering = true);

    try {
      final response = await http.post(
        Uri.parse('$_backendUrl/api/conductors/register'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'fullName': name, 'email': email}),
      ).timeout(const Duration(seconds: 10));

      final data = json.decode(response.body);

      if (response.statusCode == 200 && data['success'] == true) {
        final assignedCallSign = data['callSign'] ?? "BUS100";
        _showFsmSuccessDialog(assignedCallSign);
      } else {
        _showSnackbar(data['error'] ?? "Registration failed.", const Color(0xFFC62828));
      }
    } catch (e) {
      _showSnackbar("Failed to register. Check server connection.", const Color(0xFFC62828));
    } finally {
      if (mounted) setState(() => _isRegistering = false);
    }
  }

  void _showSnackbar(String message, Color bgColor) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: bgColor,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showFsmSuccessDialog(String callSign) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Row(
          children: [
            Icon(Icons.check_circle_rounded, color: Color(0xFF2E7D32), size: 28),
            SizedBox(width: 8),
            Text("Registration Success", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "The conductor is successfully registered.",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.black87),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF2E7D32).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF2E7D32)),
              ),
              child: Text(
                "The conductor ID is : $callSign",
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF2E7D32)),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2E7D32)),
            onPressed: () {
              Navigator.of(ctx).pop();
              // Reset to fresh form
              setState(() {
                _nameController.clear();
                _emailController.clear();
                _otpController.clear();
                _isOtpSent = false;
                _isEmailVerified = false;
              });
            },
            child: const Text("OK", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFBFBFB),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.black87),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          "Conductor Registration",
          style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 18),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 12.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 22.0, vertical: 26.0),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.black26, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 12,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Bus Brand Logo
                    Container(
                      height: 85,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: Colors.white,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.asset('assets/images/red_bus.png', fit: BoxFit.contain),
                      ),
                    ),

                    const SizedBox(height: 8),

                    // Kannada Title
                    const Text(
                      "ವಿಜಯಪುರ ನಗರ ಸಾರಿಗೆ",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF212121),
                        letterSpacing: 0.3,
                      ),
                    ),

                    const SizedBox(height: 26),

                    // 1. Conductor Name Field
                    TextField(
                      controller: _nameController,
                      decoration: InputDecoration(
                        labelText: "Conductor Full Name",
                        prefixIcon: const Icon(Icons.person_outline, color: Color(0xFFC62828)),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: Color(0xFFC62828), width: 1.8),
                        ),
                      ),
                    ),

                    const SizedBox(height: 18),

                    // 2. Conductor Email Field + Send Code Button
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            enabled: !_isEmailVerified,
                            decoration: InputDecoration(
                              labelText: "Conductor Email",
                              prefixIcon: const Icon(Icons.email_outlined, color: Color(0xFFC62828)),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: const BorderSide(color: Color(0xFFC62828), width: 1.8),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          height: 52,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _isEmailVerified ? Colors.grey : const Color(0xFFC62828),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              padding: const EdgeInsets.symmetric(horizontal: 14),
                            ),
                            onPressed: (_isSendingOtp || _isEmailVerified) ? null : _handleSendOtp,
                            child: _isSendingOtp
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                  )
                                : Text(
                                    _isOtpSent ? "Resend" : "Send Code",
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                                  ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 18),

                    // 3. Verification Code Input + Verify Button + Green Check Indicator
                    if (_isOtpSent)
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _otpController,
                              keyboardType: TextInputType.number,
                              maxLength: 6,
                              enabled: !_isEmailVerified,
                              decoration: InputDecoration(
                                counterText: "",
                                labelText: "6-Digit Code",
                                prefixIcon: const Icon(Icons.lock_clock_outlined, color: Color(0xFFC62828)),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(color: Color(0xFFC62828), width: 1.8),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          if (_isEmailVerified)
                            Container(
                              height: 52,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              decoration: BoxDecoration(
                                color: const Color(0xFF2E7D32).withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFF2E7D32), width: 1.5),
                              ),
                              child: const Row(
                                children: [
                                  Icon(Icons.check_circle, color: Color(0xFF2E7D32), size: 22),
                                  SizedBox(width: 6),
                                  Text(
                                    "Verified",
                                    style: TextStyle(
                                      color: Color(0xFF2E7D32),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            SizedBox(
                              height: 52,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF2E7D32),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                ),
                                onPressed: _isVerifyingOtp ? null : _handleVerifyOtp,
                                child: _isVerifyingOtp
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                      )
                                    : const Text(
                                        "Verify",
                                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                      ),
                              ),
                            ),
                        ],
                      ),

                    const SizedBox(height: 28),

                    // 4. Register Button
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isEmailVerified ? const Color(0xFFC62828) : Colors.grey.shade400,
                          foregroundColor: Colors.white,
                          elevation: _isEmailVerified ? 2 : 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: (_isRegistering || !_isEmailVerified) ? null : _handleRegisterConductor,
                        child: _isRegistering
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                              )
                            : const Text(
                                "Register",
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}