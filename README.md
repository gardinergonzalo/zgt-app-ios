# ZGT iOS 0.1.0

Primera base nativa de la app iPhone de ZGT.

## Objetivo

- Vinculación con el mismo código `ZGT-XXXX-XXXX` usado por Android.
- Resolución contra `https://zgt.zeoz.com.ar/wp-json/gtc/v1/app/resolve`.
- Carga del taller en `WKWebView` con almacenamiento/cookies persistentes.
- Bridge JavaScript `window.ZGTNative` compatible con ZEOZ - ZGT Print.
- Impresión nativa NIIMBOT B1 Pro con CoreBluetooth, modelo ID 4097, 300 dpi, protocolo V4, etiqueta 50 × 30 mm / 576 × 354 px.
- Cámara habilitable desde WKWebView para el lector QR del Gestor.

## Bridge disponible

```js
ZGTNative.appVersion()
ZGTNative.printNiimbotB1Pro(dataUrl)
ZGTNative.disconnectNiimbotB1Pro()
ZGTNative.isNiimbotB1ProConnected()
```

Los estados de impresión vuelven a la web por:

```js
window.ZEOZZGTPrintNativeCallback(...)
```

## Abrir en Xcode

Este proyecto usa `XcodeGen` para evitar guardar un `.xcodeproj` frágil a mano.

1. Instalar Xcode desde Apple.
2. Instalar XcodeGen en la Mac (`brew install xcodegen`).
3. En Terminal, dentro de esta carpeta, ejecutar `xcodegen generate`.
4. Abrir `ZGTiOS.xcodeproj`.
5. En **Signing & Capabilities**, seleccionar tu equipo de Apple Developer.
6. Elegir tu iPhone físico y ejecutar.

Para una prueba local en un iPhone se puede usar el equipo personal de Xcode. Para TestFlight/App Store será necesaria una membresía Apple Developer activa.

## Estado de esta versión

Es una primera versión de prueba orientada a validar en hardware real:

1. vinculación,
2. sesión WordPress,
3. navegación dentro del taller,
4. detección del bridge por ZGT Print,
5. conexión e impresión B1 Pro desde CoreBluetooth.

Luego de esa prueba se recomienda agregar/afinar: icono final, tratamiento de PDFs/compartir, selector visual cuando haya más de una impresora B1 cercana, flujo de desvinculación y distribución TestFlight.
