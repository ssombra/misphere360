#!/usr/bin/env python3
"""
Construye la aplicación nativa independiente de macOS:
  /Users/ssombra/Documents/Apps/MiSphere/Mi Sphere 360.app

Características de la app nativa:
- Ejecutable Mach-O nativo en Objective-C (Cocoa + WebKit WKWebView).
- Ícono de alta resolución (.icns) generado con CoreGraphics + iconutil.
- Inicia automáticamente app_server.py en segundo plano sin abrir Terminal.
- Al cerrar la ventana (botón rojo o Cmd+Q), detiene la vista en vivo, desconecta
  la cámara limpiamente y apaga el servidor Python en segundo plano.
- Soporta diálogos nativos de confirmación (NSAlert), ventanas secundarias de vista previa,
  atajos de teclado (Cmd+C, Cmd+V, Cmd+R, Cmd+Q) y selectores de carpetas de Finder.
"""

import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

BASE_DIR = Path(__file__).parent.resolve()
APP_NAME = "Mi Sphere 360.app"
APP_BUNDLE = BASE_DIR / APP_NAME
CONTENTS_DIR = APP_BUNDLE / "Contents"
MACOS_DIR = CONTENTS_DIR / "MacOS"
RESOURCES_DIR = CONTENTS_DIR / "Resources"

ICON_GEN_OBJC = r"""
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc < 2) return 1;
        NSString *outPath = [NSString stringWithUTF8String:argv[1]];
        int size = 1024;

        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
            pixelsWide:size
            pixelsHigh:size
            bitsPerSample:8
            samplesPerPixel:4
            hasAlpha:YES
            isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace
            bytesPerRow:size * 4
            bitsPerPixel:32];

        NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:ctx];

        // Fondo squircle estilo macOS Big Sur / Sonoma
        NSRect bgRect = NSMakeRect(64, 64, 896, 896);
        NSBezierPath *squircle = [NSBezierPath bezierPathWithRoundedRect:bgRect xRadius:200 yRadius:200];

        NSGradient *bgGrad = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0.11 green:0.14 blue:0.20 alpha:1.0]
                                                           endingColor:[NSColor colorWithCalibratedRed:0.05 green:0.07 blue:0.10 alpha:1.0]];
        [bgGrad drawInBezierPath:squircle angle:-60.0];

        // Borde sutil naranja/gris
        [[NSColor colorWithCalibratedRed:1.0 green:0.40 blue:0.0 alpha:0.45] setStroke];
        [squircle setLineWidth:12.0];
        [squircle stroke];

        // Meridiano y paralelo 360° de fondo
        [[NSColor colorWithCalibratedRed:1.0 green:0.45 blue:0.05 alpha:0.22] setStroke];
        NSBezierPath *globe = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(164, 164, 696, 696)];
        [globe setLineWidth:10.0];
        [globe stroke];

        NSBezierPath *meridian = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(330, 164, 364, 696)];
        [meridian setLineWidth:8.0];
        [meridian stroke];

        NSBezierPath *equator = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(164, 380, 696, 264)];
        [equator setLineWidth:8.0];
        [equator stroke];

        // Lente principal Fisheye central con resplandor naranja Xiaomi (#FF6700)
        NSRect outerRing = NSMakeRect(262, 292, 500, 500);
        NSBezierPath *outerPath = [NSBezierPath bezierPathWithOvalInRect:outerRing];
        NSGradient *orangeGrad = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:1.0 green:0.52 blue:0.12 alpha:1.0]
                                                               endingColor:[NSColor colorWithCalibratedRed:0.95 green:0.24 blue:0.0 alpha:1.0]];
        [orangeGrad drawInBezierPath:outerPath angle:-45.0];

        // Interior oscuro del lente
        NSRect lensRect = NSMakeRect(306, 336, 412, 412);
        NSBezierPath *lensPath = [NSBezierPath bezierPathWithOvalInRect:lensRect];
        NSGradient *lensGrad = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0.16 green:0.20 blue:0.29 alpha:1.0]
                                                             endingColor:[NSColor colorWithCalibratedRed:0.04 green:0.05 blue:0.08 alpha:1.0]];
        [lensGrad drawInBezierPath:lensPath angle:-45.0];

        // Reflejo óptico del lente
        NSBezierPath *glint1 = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(370, 560, 120, 90)];
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.28] setFill];
        [glint1 fill];

        NSBezierPath *glint2 = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(530, 410, 64, 64)];
        [[NSColor colorWithCalibratedRed:1.0 green:0.45 blue:0.0 alpha:0.35] setFill];
        [glint2 fill];

        // Etiqueta inferior "360°"
        NSRect pillRect = NSMakeRect(332, 138, 360, 108);
        NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:pillRect xRadius:54 yRadius:54];
        [orangeGrad drawInBezierPath:pill angle:0.0];

        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:74 weight:NSFontWeightHeavy],
            NSForegroundColorAttributeName: [NSColor whiteColor]
        };
        NSString *label = @"360°";
        NSSize textSize = [label sizeWithAttributes:attrs];
        NSPoint textPt = NSMakePoint(
            pillRect.origin.x + (pillRect.size.width - textSize.width) / 2.0,
            pillRect.origin.y + (pillRect.size.height - textSize.height) / 2.0 - 2.0
        );
        [label drawAtPoint:textPt withAttributes:attrs];

        [NSGraphicsContext restoreGraphicsState];

        NSData *pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [pngData writeToFile:outPath atomically:YES];
    }
    return 0;
}
"""

APP_MAIN_OBJC = r"""
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

__asm__(
    ".global _backend_tar_start\n"
    ".global _backend_tar_end\n"
    "_backend_tar_start:\n"
    ".incbin \"__BACKEND_TAR_PATH__\"\n"
    "_backend_tar_end:\n"
);
extern const uint8_t backend_tar_start[];
extern const uint8_t backend_tar_end[];

@interface AppDelegate : NSObject <NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate, NSWindowDelegate>
@property (strong, nonatomic) NSWindow *mainWindow;
@property (strong, nonatomic) WKWebView *webView;
@property (strong, nonatomic) NSMutableArray<NSWindow *> *popupWindows;
@property (strong, nonatomic) NSTask *serverTask;
@property (strong, nonatomic) NSFileHandle *logFileHandle;
@property (assign, nonatomic) int serverPort;
@property (copy, nonatomic) NSString *runtimeDir;
@end

@implementation AppDelegate

- (void)setupMenus {
    NSMenu *menubar = [[NSMenu alloc] init];
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:appMenuItem];
    [NSApp setMainMenu:menubar];

    // Menú de Aplicación
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Mi Sphere 360"];
    [appMenu addItemWithTitle:@"Acerca de Mi Sphere 360" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Recargar Panel" action:@selector(reloadWebView:) keyEquivalent:@"r"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Ocultar Mi Sphere 360" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Salir de Mi Sphere 360" action:@selector(terminate:) keyEquivalent:@"q"];
    [appMenuItem setSubmenu:appMenu];

    // Menú Edición (necesario para cortar/copiar/pegar en inputs dentro de WKWebView)
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:editMenuItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edición"];
    [editMenu addItemWithTitle:@"Deshacer" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Rehacer" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cortar" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copiar" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Pegar" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Seleccionar todo" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenuItem setSubmenu:editMenu];

    // Menú Ventana
    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:windowMenuItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Ventana"];
    [windowMenu addItemWithTitle:@"Minimizar" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Pantalla Completa" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    [windowMenuItem setSubmenu:windowMenu];
}

- (void)reloadWebView:(id)sender {
    NSURL *appURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/", self.serverPort]];
    [self.webView loadRequest:[NSURLRequest requestWithURL:appURL]];
}

- (void)extractEmbeddedBackend {
    self.runtimeDir = @"/tmp/misphere_runtime";
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:self.runtimeDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *tarPath = @"/tmp/misphere_runtime.tar.gz";
    size_t len = (size_t)(backend_tar_end - backend_tar_start);
    NSData *tarData = [NSData dataWithBytesNoCopy:(void *)backend_tar_start length:len freeWhenDone:NO];
    [tarData writeToFile:tarPath atomically:YES];

    NSTask *tarTask = [[NSTask alloc] init];
    [tarTask setLaunchPath:@"/usr/bin/tar"];
    [tarTask setArguments:@[@"-xzf", tarPath, @"-C", self.runtimeDir]];
    @try {
        [tarTask launch];
        [tarTask waitUntilExit];
    } @catch (NSException *e) {}

    NSString *coreBin = [self.runtimeDir stringByAppendingPathComponent:@"misphere_stitch_core"];
    chmod([coreBin UTF8String], 0755);
}

- (void)startPythonBackend {
    [self extractEmbeddedBackend];

    // Asegurar que PATH incluya /opt/homebrew/bin para ffmpeg y herramientas del sistema
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    NSString *oldPath = env[@"PATH"] ?: @"/usr/bin:/bin:/usr/sbin:/sbin";
    env[@"PATH"] = [NSString stringWithFormat:@"/opt/homebrew/bin:/usr/local/bin:%@", oldPath];
    env[@"PYTHONUNBUFFERED"] = @"1";

    // Cerrar cualquier instancia previa de app_server.py para evitar conflicto de puerto 8080 o sesión TCP duplicada
    NSTask *killTask = [[NSTask alloc] init];
    [killTask setLaunchPath:@"/usr/bin/pkill"];
    [killTask setArguments:@[@"-f", @"app_server.py"]];
    @try {
        [killTask launch];
        [killTask waitUntilExit];
    } @catch (NSException *e) {}

    [NSThread sleepForTimeInterval:0.15];

    // Seleccionar el intérprete Python 3 disponible (priorizando Python 3.12 del sistema del usuario)
    NSArray *pythonCandidates = @[
        @"/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
        @"/opt/homebrew/bin/python3",
        @"/usr/local/bin/python3",
        @"/usr/bin/python3"
    ];
    NSString *pythonBin = @"/usr/bin/python3";
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *cand in pythonCandidates) {
        if ([fm isExecutableFileAtPath:cand]) {
            pythonBin = cand;
            break;
        }
    }

    self.serverTask = [[NSTask alloc] init];
    [self.serverTask setCurrentDirectoryPath:self.runtimeDir];
    [self.serverTask setEnvironment:env];
    [self.serverTask setLaunchPath:pythonBin];
    NSString *scriptPath = [self.runtimeDir stringByAppendingPathComponent:@"app_server.py"];
    NSString *portStr = [NSString stringWithFormat:@"%d", self.serverPort];
    [self.serverTask setArguments:@[scriptPath, portStr]];

    // Redirigir salida a /tmp/misphere_app_server.log
    NSString *logPath = @"/tmp/misphere_app_server.log";
    [@"" writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    self.logFileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (self.logFileHandle) {
        [self.serverTask setStandardOutput:self.logFileHandle];
        [self.serverTask setStandardError:self.logFileHandle];
    }

    @try {
        [self.serverTask launch];
    } @catch (NSException *exception) {
        NSString *errStr = [NSString stringWithFormat:@"Error al lanzar python3: %@", exception];
        [errStr writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

- (BOOL)isBackendReady {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return NO;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(self.serverPort);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    int r = connect(sock, (struct sockaddr *)&addr, sizeof(addr));
    close(sock);
    return (r == 0);
}

- (void)showDiagnosticError:(NSString *)reason {
    NSString *logText = [NSString stringWithContentsOfFile:@"/tmp/misphere_app_server.log" encoding:NSUTF8StringEncoding error:nil] ?: @"(Sin salida en /tmp/misphere_app_server.log)";
    NSString *html = [NSString stringWithFormat:
        @"<html><body style='background:#0d1017;color:#f0f4f8;font-family:-apple-system,sans-serif;padding:40px;'>"
        @"<h2 style='color:#ff6700;'>Diagnóstico de Inicio — Mi Sphere 360</h2>"
        @"<p>%@</p>"
        @"<pre style='background:#151a24;padding:16px;border-radius:8px;color:#cbd5e1;white-space:pre-wrap;'>%@</pre>"
        @"<button onclick=\"window.location.href='http://127.0.0.1:%d/'\" style='background:#ff6700;color:#fff;border:none;padding:10px 18px;border-radius:8px;font-weight:700;cursor:pointer;'>Reintentar Conexión</button>"
        @"</body></html>",
        reason, logText, self.serverPort];
    [self.webView loadHTMLString:html baseURL:nil];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.popupWindows = [NSMutableArray array];
    self.serverPort = 8080;

    NSImage *appIcon = [NSImage imageNamed:@"AppIcon"];
    if (appIcon) {
        [NSApp setApplicationIconImage:appIcon];
    }

    [self setupMenus];

    // Iniciar primero el backend embebido en /tmp/misphere_runtime y esperar hasta ~3s a que abra el puerto 8080
    [self startPythonBackend];
    BOOL ready = NO;
    for (int i = 0; i < 60; i++) {
        if ([self isBackendReady]) {
            ready = YES;
            break;
        }
        [NSThread sleepForTimeInterval:0.05];
    }

    NSRect frame = NSMakeRect(0, 0, 1300, 860);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    self.mainWindow = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    [self.mainWindow setTitle:@"Xiaomi Mi Sphere 360 — Panel de Control Pro v1.2"];
    [self.mainWindow setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    [self.mainWindow setBackgroundColor:[NSColor colorWithCalibratedRed:0.05 green:0.06 blue:0.09 alpha:1.0]];
    [self.mainWindow setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
    [self.mainWindow setMinSize:NSMakeSize(900, 620)];
    [self.mainWindow center];
    [self.mainWindow setDelegate:self];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    @try {
        [config.preferences setValue:@YES forKey:@"fullScreenEnabled"];
    } @catch (NSException *e) {}

    self.webView = [[WKWebView alloc] initWithFrame:[[self.mainWindow contentView] bounds] configuration:config];
    [self.webView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [self.webView setUIDelegate:self];
    [self.webView setNavigationDelegate:self];

    [[self.mainWindow contentView] addSubview:self.webView];
    [self.mainWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    if (ready) {
        NSURL *appURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/", self.serverPort]];
        [self.webView loadRequest:[NSURLRequest requestWithURL:appURL]];
    } else {
        [self showDiagnosticError:@"El servidor local no respondió a tiempo en el puerto 8080."];
    }
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (error.code == NSURLErrorCancelled) return;
    [self showDiagnosticError:[NSString stringWithFormat:@"Error cargando interfaz local: %@", error.localizedDescription]];
}

// Soporte para window.alert() en WKWebView
- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Mi Sphere 360"];
    [alert setInformativeText:message];
    [alert addButtonWithTitle:@"Aceptar"];
    [alert beginSheetModalForWindow:self.mainWindow completionHandler:^(NSModalResponse returnCode) {
        completionHandler();
    }];
}

// Soporte para window.confirm() en WKWebView (usado al borrar archivos/carpetas o apagar la cámara)
- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Confirmación"];
    [alert setInformativeText:message];
    [alert addButtonWithTitle:@"Confirmar"];
    [alert addButtonWithTitle:@"Cancelar"];
    [alert beginSheetModalForWindow:self.mainWindow completionHandler:^(NSModalResponse returnCode) {
        completionHandler(returnCode == NSAlertFirstButtonReturn);
    }];
}

// Soporte para enlaces target="_blank" (ej. Ver Original o reproducir video MP4 en ventana secundaria nativa)
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
    NSRect popupFrame = NSMakeRect(0, 0, 980, 680);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSWindow *popupWin = [[NSWindow alloc] initWithContentRect:popupFrame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    [popupWin setTitle:@"Vista Previa — Mi Sphere 360"];
    [popupWin setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    [popupWin setBackgroundColor:[NSColor blackColor]];
    [popupWin center];
    [popupWin setReleasedWhenClosed:NO];

    WKWebView *popupWeb = [[WKWebView alloc] initWithFrame:[[popupWin contentView] bounds] configuration:configuration];
    [popupWeb setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [popupWeb setUIDelegate:self];
    [[popupWin contentView] addSubview:popupWeb];
    [self.popupWindows addObject:popupWin];
    [popupWin makeKeyAndOrderFront:nil];

    return popupWeb;
}

- (void)windowWillClose:(NSNotification *)notification {
    if ([notification object] == self.mainWindow) {
        [NSApp terminate:nil];
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (self.serverTask != nil && [self.serverTask isRunning]) {
        [self.serverTask terminate];
        [self.serverTask waitUntilExit];
    }
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
"""


def build_icns(dest_icns: Path):
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        objc_file = tmp / "gen_icon.m"
        bin_file = tmp / "gen_icon"
        master_png = tmp / "icon_1024.png"
        iconset_dir = tmp / "AppIcon.iconset"
        iconset_dir.mkdir(parents=True, exist_ok=True)

        objc_file.write_text(ICON_GEN_OBJC, encoding="utf-8")
        subprocess.run(
            ["clang", "-O2", "-ObjC", "-framework", "Cocoa", "-framework", "CoreGraphics", str(objc_file), "-o", str(bin_file)],
            check=True,
        )
        subprocess.run([str(bin_file), str(master_png)], check=True)

        sizes = [
            (16, "icon_16x16.png"),
            (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"),
            (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"),
            (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png"),
        ]
        for px, name in sizes:
            out_png = iconset_dir / name
            subprocess.run(
                ["sips", "-z", str(px), str(px), str(master_png), "--out", str(out_png)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=True,
            )

        subprocess.run(["iconutil", "-c", "icns", str(iconset_dir), "-o", str(dest_icns)], check=True)


def build_app():
    if APP_BUNDLE.exists():
        shutil.rmtree(APP_BUNDLE)

    MACOS_DIR.mkdir(parents=True, exist_ok=True)
    RESOURCES_DIR.mkdir(parents=True, exist_ok=True)

    # 1. Generar ícono AppIcon.icns
    icns_path = RESOURCES_DIR / "AppIcon.icns"
    build_icns(icns_path)

    # 2. Crear archivo tar.gz del backend y embeberlo directamente en el binario Mach-O vía .incbin
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp_path = Path(tmpdir)
        stage_dir = tmp_path / "stage"
        stage_dir.mkdir(parents=True, exist_ok=True)

        files_to_bundle = [
            "app_server.py",
            "misphere_controller.py",
            "stitch_photos.py",
            "fix_photo_dates.py",
            "misphere_stitch_core",
            "factory_lut_cached.bin",
            "factory_lut_webgl.bin",
            "camera_report.json",
        ]
        for fname in files_to_bundle:
            src = BASE_DIR / fname
            if src.exists():
                dst = stage_dir / fname
                shutil.copy2(src, dst)
                if fname == "misphere_stitch_core":
                    os.chmod(dst, 0o755)

        static_src = BASE_DIR / "static"
        if static_src.exists():
            shutil.copytree(static_src, stage_dir / "static", dirs_exist_ok=True)

        tar_path = tmp_path / "backend.tar.gz"
        subprocess.run(
            ["tar", "-czf", str(tar_path), "-C", str(stage_dir), "."],
            check=True,
        )

        objc_code = APP_MAIN_OBJC.replace("__BACKEND_TAR_PATH__", str(tar_path))
        m_path = tmp_path / "main.m"
        m_path.write_text(objc_code, encoding="utf-8")

        exe_path = MACOS_DIR / "MiSphere360"
        subprocess.run(
            [
                "clang",
                "-O2",
                "-fobjc-arc",
                "-ObjC",
                "-framework", "Cocoa",
                "-framework", "WebKit",
                str(m_path),
                "-o", str(exe_path),
            ],
            check=True,
        )
        os.chmod(exe_path, 0o755)

    # 3. Escribir Info.plist
    info_plist = {
        "CFBundleName": "Mi Sphere 360",
        "CFBundleDisplayName": "Mi Sphere 360",
        "CFBundleIdentifier": "com.ssombra.misphere360",
        "CFBundleVersion": "1.2.0",
        "CFBundleShortVersionString": "1.2",
        "CFBundlePackageType": "APPL",
        "CFBundleExecutable": "MiSphere360",
        "CFBundleIconFile": "AppIcon",
        "LSMinimumSystemVersion": "12.0",
        "NSHighResolutionCapable": True,
        "NSLocalNetworkUsageDescription": (
            "Mi Sphere 360 necesita comunicarse por Wi-Fi con tu cámara Xiaomi Mi Sphere 360 (192.168.42.1)."
        ),
        "NSAppTransportSecurity": {
            "NSAllowsArbitraryLoads": True,
            "NSAllowsLocalNetworking": True,
        },
    }
    with (CONTENTS_DIR / "Info.plist").open("wb") as fp:
        plistlib.dump(info_plist, fp)

    # 4. Firma ad-hoc para macOS y refresco de caché de ícono en Finder/Dock
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(APP_BUNDLE)], check=True)
    subprocess.run(["touch", str(APP_BUNDLE)], check=False)
    lsreg = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if Path(lsreg).exists():
        subprocess.run([lsreg, "-f", str(APP_BUNDLE)], check=False)
    print(f"✅ Aplicación nativa v1.2 creada exitosamente en:\n   {APP_BUNDLE}")


if __name__ == "__main__":
    build_app()
