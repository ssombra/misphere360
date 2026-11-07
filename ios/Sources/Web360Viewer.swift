import SwiftUI
import WebKit
import CoreMotion

/// Visor WebGL 360° idéntico al de la app web de Mac con control táctil ultra-suave y giroscopio opcional
public struct Web360Viewer: UIViewRepresentable {
    let image: UIImage
    var enableMotion: Bool = false

    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        let html = generateViewerHTML()
        webView.loadHTMLString(html, baseURL: nil)

        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.isReady {
            context.coordinator.sendImageToWebGL(image)
        } else {
            context.coordinator.pendingImage = image
        }

        context.coordinator.setMotionEnabled(enableMotion)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public class Coordinator: NSObject, WKNavigationDelegate {
        var parent: Web360Viewer
        weak var webView: WKWebView?
        var isReady = false
        var pendingImage: UIImage?
        var lastSentImageID: ObjectIdentifier?

        private let motionManager = CMMotionManager()
        private var isMotionActive = false
        private var lastAttitude: CMAttitude?

        init(parent: Web360Viewer) {
            self.parent = parent
        }

        deinit {
            motionManager.stopDeviceMotionUpdates()
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            if let img = pendingImage {
                sendImageToWebGL(img)
                pendingImage = nil
            }
        }

        func sendImageToWebGL(_ img: UIImage) {
            let imgID = ObjectIdentifier(img)
            if imgID == lastSentImageID { return }
            lastSentImageID = imgID

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // Redimensionar para WebGL móvil si es necesario (máximo 4096 de ancho para fluidez de 60 FPS)
                let targetImage = self?.resizeForWebGL(img, maxDimension: 4096) ?? img
                guard let data = targetImage.jpegData(compressionQuality: 0.85) else { return }
                let base64 = data.base64EncodedString()

                DispatchQueue.main.async {
                    let js = "window.setImageData && window.setImageData('\(base64)');"
                    self?.webView?.evaluateJavaScript(js, completionHandler: nil)
                }
            }
        }

        private func resizeForWebGL(_ img: UIImage, maxDimension: CGFloat) -> UIImage {
            let size = img.size
            if size.width <= maxDimension && size.height <= maxDimension {
                return img
            }
            let aspect = size.width / size.height
            let newWidth: CGFloat
            let newHeight: CGFloat
            if aspect >= 1.0 {
                newWidth = maxDimension
                newHeight = maxDimension / aspect
            } else {
                newHeight = maxDimension
                newWidth = maxDimension * aspect
            }

            let renderer = UIGraphicsImageRenderer(size: CGSize(width: newWidth, height: newHeight))
            return renderer.image { _ in
                img.draw(in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
            }
        }

        func setMotionEnabled(_ enable: Bool) {
            if enable == isMotionActive { return }
            isMotionActive = enable

            if enable {
                guard motionManager.isDeviceMotionAvailable else { return }
                motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
                motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
                    guard let self = self, let motion = motion else { return }
                    let m = motion.attitude.rotationMatrix
                    let yaw = Float(atan2(m.m13, -m.m23))
                    let pitch = Float(asin(max(-1.0, min(1.0, -m.m33))))
                    let js = "window.setGyroOrientation && window.setGyroOrientation(\(yaw), \(pitch));"
                    self.webView?.evaluateJavaScript(js, completionHandler: nil)
                }
            } else {
                motionManager.stopDeviceMotionUpdates()
                webView?.evaluateJavaScript("window.disableGyro && window.disableGyro();", completionHandler: nil)
            }
        }
    }

    private func generateViewerHTML() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
          * { margin:0; padding:0; box-sizing:border-box; -webkit-touch-callout:none; -webkit-user-select:none; }
          body, html { width:100%; height:100%; overflow:hidden; background:#000; touch-action:none; }
          canvas { width:100%; height:100%; display:block; }
        </style>
        </head>
        <body>
        <canvas id="c"></canvas>
        <script>
          let gl, prog, tex;
          let yaw = 0.0, pitch = 0.0, fovDeg = 75.0;
          let gyroYaw = 0.0, gyroPitch = 0.0;
          let gyroOffsetYaw = 0.0, gyroOffsetPitch = 0.0;
          let isGyroEnabled = false;
          let dragging = false, lastX = 0, lastY = 0;
          let lastDist = 0;
          let hasImage = false;

          const vs = `
            attribute vec2 aPos;
            varying vec2 vNdc;
            void main() {
              vNdc = aPos;
              gl_Position = vec4(aPos, 0.0, 1.0);
            }
          `;

          // Shader de proyección esférica equirrectangular 360° exacto de la Mac
          const fs = `
            precision highp float;
            varying vec2 vNdc;
            uniform sampler2D uTex;
            uniform float uYaw;
            uniform float uPitch;
            uniform float uTanHalfFov;
            uniform float uAspect;
            const float PI = 3.141592653589793;

            void main() {
              vec3 dir = normalize(vec3(vNdc.x * uTanHalfFov * uAspect, vNdc.y * uTanHalfFov, -1.0));
              float cp = cos(uPitch), sp = sin(uPitch);
              vec3 d1 = vec3(dir.x, dir.y * cp - dir.z * sp, dir.y * sp + dir.z * cp);
              float cy = cos(uYaw), sy = sin(uYaw);
              vec3 worldDir = vec3(d1.x * cy - d1.z * sy, d1.y, d1.x * sy + d1.z * cy);

              float lon = atan(worldDir.x, -worldDir.z);
              float lat = asin(clamp(worldDir.y, -1.0, 1.0));
              float u = fract(lon / (2.0 * PI) + 0.5);
              float v = clamp(0.5 - lat / PI, 0.0, 1.0);
              gl_FragColor = texture2D(uTex, vec2(u, v));
            }
          `;

          function init() {
            const canvas = document.getElementById("c");
            gl = canvas.getContext("webgl", { antialias: true, preserveDrawingBuffer: false, powerPreference: "high-performance" });
            if (!gl) return;

            function createShader(type, src) {
              const s = gl.createShader(type);
              gl.shaderSource(s, src);
              gl.compileShader(s);
              return s;
            }

            prog = gl.createProgram();
            gl.attachShader(prog, createShader(gl.VERTEX_SHADER, vs));
            gl.attachShader(prog, createShader(gl.FRAGMENT_SHADER, fs));
            gl.linkProgram(prog);
            gl.useProgram(prog);

            const quad = new Float32Array([-1,-1, 1,-1, -1,1, -1,1, 1,-1, 1,1]);
            const buf = gl.createBuffer();
            gl.bindBuffer(gl.ARRAY_BUFFER, buf);
            gl.bufferData(gl.ARRAY_BUFFER, quad, gl.STATIC_DRAW);

            const aPos = gl.getAttribLocation(prog, "aPos");
            gl.enableVertexAttribArray(aPos);
            gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);

            tex = gl.createTexture();
            gl.bindTexture(gl.TEXTURE_2D, tex);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);

            // Controles táctiles idénticos a la app web de Mac
            canvas.addEventListener("touchstart", e => {
              if (e.touches.length === 1) {
                dragging = true;
                lastX = e.touches[0].clientX;
                lastY = e.touches[0].clientY;
              } else if (e.touches.length === 2) {
                dragging = false;
                lastDist = Math.hypot(
                  e.touches[0].clientX - e.touches[1].clientX,
                  e.touches[0].clientY - e.touches[1].clientY
                );
              }
            }, { passive: true });

            canvas.addEventListener("touchmove", e => {
              if (dragging && e.touches.length === 1) {
                const dx = e.touches[0].clientX - lastX;
                const dy = e.touches[0].clientY - lastY;
                lastX = e.touches[0].clientX;
                lastY = e.touches[0].clientY;
                const sens = (fovDeg / 75.0) * 0.0035;
                if (isGyroEnabled) {
                  gyroOffsetYaw -= dx * sens;
                  gyroOffsetPitch = Math.max(-1.50, Math.min(1.50, gyroOffsetPitch + dy * sens));
                } else {
                  yaw -= dx * sens;
                  pitch = Math.max(-1.52, Math.min(1.52, pitch + dy * sens));
                }
              } else if (e.touches.length === 2) {
                const dist = Math.hypot(
                  e.touches[0].clientX - e.touches[1].clientX,
                  e.touches[0].clientY - e.touches[1].clientY
                );
                if (lastDist > 0) {
                  const factor = dist / lastDist;
                  fovDeg = Math.max(30, Math.min(110, fovDeg / factor));
                }
                lastDist = dist;
              }
            }, { passive: true });

            canvas.addEventListener("touchend", () => {
              dragging = false;
              lastDist = 0;
            });

            // Doble toque para centrar vista
            let lastTapTime = 0;
            canvas.addEventListener("touchend", e => {
              const now = Date.now();
              if (now - lastTapTime < 300) {
                yaw = 0.0;
                pitch = 0.0;
                fovDeg = 75.0;
                gyroOffsetYaw = -gyroYaw;
                gyroOffsetPitch = -gyroPitch;
              }
              lastTapTime = now;
            });

            requestAnimationFrame(render);
          }

          window.setImageData = function(b64) {
            const img = new Image();
            img.onload = () => {
              gl.bindTexture(gl.TEXTURE_2D, tex);
              gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, img);
              hasImage = true;
            };
            img.src = "data:image/jpeg;base64," + b64;
          };

          window.setGyroOrientation = function(y, p) {
            if (!isGyroEnabled) {
              gyroOffsetYaw = yaw - y;
              gyroOffsetPitch = pitch - p;
              isGyroEnabled = true;
            }
            gyroYaw = y;
            gyroPitch = p;
          };

          window.disableGyro = function() {
            isGyroEnabled = false;
          };

          function render() {
            if (gl && hasImage) {
              if (isGyroEnabled && !dragging) {
                let targetY = gyroYaw + gyroOffsetYaw;
                let diffY = targetY - yaw;
                diffY = ((diffY + Math.PI) % (2.0 * Math.PI)) - Math.PI;
                yaw += diffY * 0.22;

                let targetP = Math.max(-1.50, Math.min(1.50, gyroPitch + gyroOffsetPitch));
                pitch += (targetP - pitch) * 0.22;
              }

              const canvas = document.getElementById("c");
              const dpr = Math.min(window.devicePixelRatio || 1, 2);
              const w = Math.floor(canvas.clientWidth * dpr);
              const h = Math.floor(canvas.clientHeight * dpr);
              if (canvas.width !== w || canvas.height !== h) {
                canvas.width = w;
                canvas.height = h;
              }

              gl.viewport(0, 0, canvas.width, canvas.height);
              gl.useProgram(prog);
              gl.uniform1f(gl.getUniformLocation(prog, "uYaw"), yaw);
              gl.uniform1f(gl.getUniformLocation(prog, "uPitch"), pitch);
              gl.uniform1f(gl.getUniformLocation(prog, "uTanHalfFov"), Math.tan((fovDeg * Math.PI) / 360.0));
              gl.uniform1f(gl.getUniformLocation(prog, "uAspect"), canvas.width / Math.max(1, canvas.height));
              gl.drawArrays(gl.TRIANGLES, 0, 6);
            }
            requestAnimationFrame(render);
          }

          window.addEventListener("DOMContentLoaded", init);
        </script>
        </body>
        </html>
        """
    }
}
