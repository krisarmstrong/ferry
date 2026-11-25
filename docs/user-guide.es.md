# Guía del usuario de Ferry

<!-- Generado desde Sources/FerryUI/help.json y Localizable.xcstrings con `make guide`. No edites este archivo. -->

Ferry muestra los dispositivos Android como ubicaciones en Finder en tu Mac. Se creó primero para probadores de red, el LinkRunner 10G, el LinkRunner 100G, el EtherScope nXG y el CyberScope, y también funciona con el AirCheck G3 y otros teléfonos Android.

Esta guía contiene la misma ayuda que **Ayuda** en el menú de Ferry, y además cómo instalar Ferry. Ferry es gratuito y de código abierto (MIT). Necesita macOS 26 o posterior en una Mac con Apple silicon.

## Contenido

- [Instalación](#instalación)
- [Primeros pasos](#primeros-pasos)
  - [Qué hace Ferry](#qué-hace-ferry)
  - [Activar Ferry en Finder](#activar-ferry-en-finder)
  - [Conecta tu primer dispositivo](#conecta-tu-primer-dispositivo)
- [Conexión](#conexión)
  - [Conectar un probador de red](#conectar-un-probador-de-red)
  - [Conectar un AirCheck G3](#conectar-un-aircheck-g3)
  - [Conectar un teléfono Android](#conectar-un-teléfono-android)
  - [Activar la depuración por USB](#activar-la-depuración-por-usb)
  - [Obtener adb](#obtener-adb)
  - [Permitir esta Mac en el dispositivo](#permitir-esta-mac-en-el-dispositivo)
  - [Usar un dispositivo por Wi-Fi](#usar-un-dispositivo-por-wi-fi)
  - [Conectar por dirección](#conectar-por-dirección)
  - [Vincular con un código](#vincular-con-un-código)
  - [Dispositivos recordados](#dispositivos-recordados)
- [Archivos en Finder](#archivos-en-finder)
  - [Encuentra tu dispositivo en Finder](#encuentra-tu-dispositivo-en-finder)
  - [Copiar archivos](#copiar-archivos)
  - [Renombrar y eliminar](#renombrar-y-eliminar)
  - [Cuando un archivo cambió en ambos lados](#cuando-un-archivo-cambió-en-ambos-lados)
  - [Ver los cambios hechos en el dispositivo](#ver-los-cambios-hechos-en-el-dispositivo)
  - [Enviar archivos desde Finder](#enviar-archivos-desde-finder)
  - [Libera espacio en la Mac](#libera-espacio-en-la-mac)
- [El menú](#el-menú)
  - [Leer el menú](#leer-el-menú)
  - [Detalles del dispositivo y direcciones](#detalles-del-dispositivo-y-direcciones)
  - [Herramientas del dispositivo](#herramientas-del-dispositivo)
  - [Tomar una captura de pantalla o grabar la pantalla](#tomar-una-captura-de-pantalla-o-grabar-la-pantalla)
  - [Instalar una app](#instalar-una-app)
  - [Enviar un archivo desde el menú](#enviar-un-archivo-desde-el-menú)
  - [Mira el registro del dispositivo](#mira-el-registro-del-dispositivo)
  - [Reenviar un puerto](#reenviar-un-puerto)
  - [Abrir un shell en Terminal](#abrir-un-shell-en-terminal)
- [Solución de problemas](#solución-de-problemas)
  - [El dispositivo no aparece](#el-dispositivo-no-aparece)
  - [Mensajes del dispositivo](#mensajes-del-dispositivo)
  - [Mensajes de depuración por USB](#mensajes-de-depuración-por-usb)
  - [Mensajes de Wi-Fi y de red](#mensajes-de-wi-fi-y-de-red)
  - [Mensajes en Finder](#mensajes-en-finder)
  - [Mensajes de Enviar a y Enviar archivo](#mensajes-de-enviar-a-y-enviar-archivo)
  - [Mensajes de instalación de apps](#mensajes-de-instalación-de-apps)
  - [Mensajes de capturas de pantalla y grabaciones](#mensajes-de-capturas-de-pantalla-y-grabaciones)
  - [Mensajes de reenvío de puertos y del registro](#mensajes-de-reenvío-de-puertos-y-del-registro)
  - [El asistente de Ferry y los ajustes](#el-asistente-de-ferry-y-los-ajustes)
  - [Diagnóstico para soporte](#diagnóstico-para-soporte)
- [Acerca de Ferry](#acerca-de-ferry)
  - [Actualizaciones](#actualizaciones)
  - [Privacidad](#privacidad)
  - [Eliminar Ferry](#eliminar-ferry)
  - [Desinstalar](#desinstalar)
  - [Agradecimientos](#agradecimientos)

## Instalación

Descarga Ferry desde la [versión más reciente](https://github.com/krisarmstrong/ferry/releases/latest), mueve **Ferry** a la carpeta **Aplicaciones** y ábrelo. A partir de ahí, Ferry se mantiene actualizado solo (consulta **Actualizaciones**).

Ferry funciona en la barra de menús. No tiene ícono en el Dock ni ventana principal. Hasta que su asistente responde, el menú muestra **Comprobando…**.

## Primeros pasos

### Qué hace Ferry

Ferry muestra los dispositivos Android como ubicaciones en Finder. Se ejecuta en la barra de menús y no tiene icono en el Dock.

La primera vez que se abre, Ferry inicia un pequeño asistente que se comunica con tus dispositivos. El asistente sigue en ejecución después de que salgas del menú, así los dispositivos permanecen en Finder.

Con un cable, Ferry usa el modo de transferencia de archivos del dispositivo. Con la depuración por USB activada, o por Wi-Fi, usa ADB, que es más rápido y agrega herramientas como capturas de pantalla e instalación de apps.

La primera vez que se abre Ferry, una ventana de bienvenida muestra lo que falta por configurar: conectar un dispositivo, activar Ferry en Finder y, para la depuración por USB o Wi-Fi, obtener adb. Cada paso se marca al completarlo.

En la Ayuda de Ferry, **Mostrar ventana de bienvenida** vuelve a abrir la bienvenida.

### Activar Ferry en Finder

macOS te pide permitir las ubicaciones de Ferry en Finder. Hasta que lo hagas, el menú muestra **Activar Ferry en Finder** una vez que se ha conectado un dispositivo.

1. Haz clic en el icono de Ferry en la barra de menús.
2. Haz clic en **Abrir Ajustes del Sistema**.
3. En Ítems de inicio y extensiones, activa Ferry en Proveedores de archivos.

Solo tienes que hacerlo una vez.

### Conecta tu primer dispositivo

1. Desbloquea el dispositivo y conéctalo a la Mac con un cable USB.
2. En el dispositivo, elige **Transferir archivos**.
3. Busca el dispositivo en la barra lateral de Finder, en Ubicaciones.

Los pasos varían un poco según el modelo. **Cómo conectar** te muestra los de tu dispositivo.

En la app, **Cómo conectar** abre la guía de configuración.

## Conexión

### Conectar un probador de red

Para el LinkRunner 10G, el LinkRunner 100G, el EtherScope nXG y el CyberScope.

1. Conecta un cable USB-C al **puerto USB-C del lado izquierdo** de la unidad y a la Mac.
2. En la unidad: **Configuración** (en la parte inferior de la pantalla de inicio) → **Dispositivos conectados** → **USB**.
3. Toca **Transferir archivos**.

El dispositivo aparece en Finder cuando comparte archivos.

En la app, **Cómo conectar** abre la guía de configuración.

### Conectar un AirCheck G3

Estos son los pasos habituales de Android, que aún no se han comprobado en ningún AirCheck G3. Si un nombre en el probador es distinto, busca la notificación de USB o la configuración de USB.

1. Conecta el probador a la Mac con un cable USB.
2. En el probador, desliza hacia abajo el panel de notificaciones y toca la notificación de USB.
3. En **Preferencias de USB**, elige **Transferencia de archivos**. O abre **Configuración** → **Dispositivos conectados** → **USB**.

El dispositivo aparece en Finder cuando comparte archivos.

En la app, **Cómo conectar** abre la guía de configuración.

### Conectar un teléfono Android

Primero desbloquea el teléfono. Su almacenamiento permanece oculto mientras está bloqueado.

En la app, **Cómo conectar** abre la guía de configuración.

#### Android 8 o 9

1. Desbloquea el teléfono y conéctalo a la Mac con un cable USB. Su almacenamiento permanece oculto mientras está bloqueado.
2. Desliza hacia abajo el panel de notificaciones y toca **Carga de este dispositivo mediante USB**.
3. Toca **Transferir archivos**.

#### Android 10 o posterior

1. Desbloquea el teléfono y conéctalo a la Mac con un cable USB. Su almacenamiento permanece oculto mientras está bloqueado.
2. Desliza hacia abajo el panel de notificaciones y toca **Cargando este dispositivo mediante USB**.
3. En **Preferencias de USB**, elige **Transferencia de archivos**. O abre **Configuración** → **Dispositivos conectados** → **USB**.

### Activar la depuración por USB

Con la depuración por USB activada, Ferry sirve el dispositivo por ADB, que es más rápido que la transferencia de archivos y agrega más herramientas. La transferencia de archivos sigue funcionando sin ella.

Los nombres de los menús varían un poco entre fabricantes de teléfonos. Busca Opciones para desarrolladores y el interruptor de Depuración por USB.

En la app, **Cómo activar la depuración por USB** abre los pasos para activar la depuración por USB.

#### LinkRunner 10G, LinkRunner 100G, EtherScope nXG o CyberScope

1. Pide a NetAlly que active ADB en el probador.
2. Después, en el probador: **Configuración** → **Sistema** → **About tester**. Toca **Número de compilación** hasta que se active el modo de desarrollador.
3. Ve a **Configuración** → **Sistema** → **Opciones para desarrolladores** y activa **Depuración por USB**.
4. Con el cable USB-C conectado a la Mac, desactiva y vuelve a activar **Depuración por USB**. El probador ofrece ADB solo después de esto.
5. En el dispositivo, marca **Permitir siempre desde esta computadora** y toca **Aceptar**.

Si el dispositivo acepta ADB por la red, usa **Conectar por dirección…**.

#### AirCheck G3 (probador Wi-Fi)

1. En el probador, abre **Configuración**, busca **Número de compilación** (normalmente en **Acerca de**) y tócalo hasta que se active el modo de desarrollador.
2. En el probador, abre **Opciones para desarrolladores** en **Configuración** y activa **Depuración por USB**.
3. En el dispositivo, marca **Permitir siempre desde esta computadora** y toca **Permitir**.

Si el dispositivo acepta ADB por la red, usa **Conectar por dirección…**.

#### Android 8 o 9

1. Desbloquea el teléfono y conéctalo a la Mac con un cable USB. Su almacenamiento permanece oculto mientras está bloqueado.
2. Abre **Configuración** → **Sistema** → **Información del teléfono** y toca **Número de compilación** hasta que se active el modo de desarrollador.
3. Abre **Configuración** → **Sistema** → **Opciones para desarrolladores** y activa **Depuración por USB**.
4. En el dispositivo, marca **Permitir siempre desde esta computadora** y toca **Aceptar**.

Si el dispositivo acepta ADB por la red, usa **Conectar por dirección…**.

#### Android 10 o posterior

1. Desbloquea el teléfono y conéctalo a la Mac con un cable USB. Su almacenamiento permanece oculto mientras está bloqueado.
2. Abre **Configuración** → **Información del teléfono** y toca **Número de compilación** hasta que se active el modo de desarrollador.
3. Abre **Configuración** → **Sistema** → **Opciones para desarrolladores** y activa **Depuración por USB**.
4. En el dispositivo, marca **Permitir siempre desde esta computadora** y toca **Permitir**.

Si el dispositivo acepta ADB por la red, usa **Conectar por dirección…**.

### Obtener adb

Ferry necesita adb, de las Android Platform Tools de Google, para la depuración por USB y Wi-Fi. La transferencia de archivos funciona sin él.

Si adb ya está en esta Mac, desde Homebrew o Android Studio, Ferry lo usa. Si no, el menú muestra **adb no está en esta Mac**, y Ferry puede descargarlo de Google por ti, una sola vez. Para eso se necesita conexión a internet.

1. Haz clic en **Obtener Android Platform Tools…** en esa línea.
2. Lee la Android SDK License de Google y haz clic en **Aceptar**.
3. Ferry descarga las Android Platform Tools de Google, comprueba que son la versión que espera y que adb está firmado por Google, y conserva solo adb y sus avisos.

Ferry guarda adb en ~/Library/Application Support/Ferry/platform-tools y registra que aceptaste la licencia, y cuándo. Cuando una actualización de Ferry necesita un adb más reciente, Ferry lo descarga de la misma manera; si Google ha cambiado la licencia, Ferry te pide aceptarla de nuevo antes. Un adb que instalaste tú también funciona, y Ferry prefiere su propia copia cuando están las dos.

### Permitir esta Mac en el dispositivo

La primera vez que un dispositivo se encuentra con esta Mac por ADB, pregunta si se permite la depuración por USB. Ferry no puede usar ADB hasta que la permitas.

Hasta entonces, el dispositivo muestra **Esperando permiso** en el menú, con **Permite la depuración por USB en el dispositivo** debajo. Por la red, el menú muestra **Esperando a que permitas esta Mac en** y la dirección.

1. Desbloquea el dispositivo.
2. Marca **Permitir siempre desde esta computadora** para que no vuelva a preguntar.
3. Toca **Aceptar** o **Permitir**.

Si el aviso nunca aparece, desconecta el cable y vuelve a conectarlo. En un probador, desactiva y vuelve a activar **Depuración por USB**.

### Usar un dispositivo por Wi-Fi

Usar por Wi-Fi es adecuado para un dispositivo que ya tiene la depuración por USB activada, como un probador de red o un teléfono con Android 8 a 10.

Ferry nunca busca en la red. Solo se conecta a las direcciones que le des y a las direcciones que informa por sí mismo un dispositivo con la depuración por USB. Un dispositivo que también está conectado por cable siempre se sirve por el cable.

La primera vez que Ferry llega a un dispositivo por la red, macOS pregunta si Ferry puede encontrar dispositivos en tu red local. Haz clic en **Permitir**: sin eso, Ferry no puede llegar a los dispositivos por Wi-Fi.

1. Conecta el dispositivo a Ethernet o a Wi-Fi.
2. Conéctalo a la Mac con un cable, con la depuración por USB activada.
3. Haz clic en el dispositivo en el menú y luego en **Usar por Wi-Fi**.
4. Desconecta el cable. Ferry sigue llegando al dispositivo por la red, así que permanece en Finder.

Activarlo reinicia ADB en el dispositivo, así que Ferry se niega mientras el dispositivo tiene una transferencia, una grabación de pantalla o un registro en curso: déjalo terminar y vuelve a intentarlo.

### Conectar por dirección

Para un dispositivo que ya acepta ADB por la red.

1. Haz clic en **Conectar por dirección…**. Se abre un campo en el menú.
2. Escribe la dirección IP o el nombre del dispositivo. Agrega un puerto después de dos puntos si no usa el puerto 5555.
3. Haz clic en **Conectar** o presiona Retorno.
4. Si el dispositivo lo pide, toca **Permitir** en él.

Presiona Escape, o haz clic de nuevo en **Conectar por dirección…**, para cerrar el campo.

### Vincular con un código

Para teléfonos con Android 11 o posterior, que se vinculan por Wi-Fi sin cable.

1. En el dispositivo, abre **Opciones para desarrolladores** → **Depuración inalámbrica** y elige **Vincular dispositivo con código de vinculación**.
2. En el menú de Ferry, haz clic en **Vincular con código…**. Se abre un formulario en el menú.
3. Ingresa la dirección IP, el puerto y el código que muestra el dispositivo.
4. Haz clic en **Vincular** o presiona Retorno.

Después, Ferry se conecta a la dirección que el dispositivo ofrece para las conexiones, que no es aquella en la que se vinculó.

### Dispositivos recordados

Ferry recuerda cada dispositivo que conecta por la red mediante su número de serie, y vuelve a conectarse a él cuando Ferry se inicia y cuando adb se reinicia. Un dispositivo recordado al que no puede llegar muestra **Recordado · no está cerca**: haz clic en él y luego en **Volver a conectar** para intentarlo de nuevo.

**Olvidar este dispositivo** desconecta el dispositivo y olvida sus direcciones. Ferry ya no se conecta a él por sí mismo.

#### ¿Esta dirección es tu dispositivo?

Cualquiera en una red puede hacerse pasar por un dispositivo con solo declarar su número de serie. Por eso, cuando una dirección nueva responde como un dispositivo que Ferry ya conoce, Ferry no la usa por su cuenta: el menú pregunta “¿*dirección* es tu *dispositivo*?”

**Usar** conecta la dirección y la recuerda para ese dispositivo. **Ignorar** la deja sin usar hasta que Ferry se reinicie.

## Archivos en Finder

### Encuentra tu dispositivo en Finder

Cada dispositivo aparece en la barra lateral de Finder, en Ubicaciones, y en los diálogos Abrir y Guardar de todas las apps.

Un dispositivo aparece en Finder solo mientras Ferry puede llegar a él. Cuando está desconectado y fuera de la red, bloqueado o sin compartir archivos, su ubicación desaparece de la barra lateral. Vuelve con sus archivos cuando Ferry pueda volver a acceder a él.

Un dispositivo con tarjeta SD muestra dos ubicaciones: su almacenamiento interno y la tarjeta, con “tarjeta SD” después del nombre. Si hay dos dispositivos del mismo modelo conectados, cada nombre termina con los últimos cuatro caracteres de su número de serie.

Haz doble clic en un archivo para abrirlo. Ferry lo copia a la Mac cuando lo abres.

Con una sola ubicación de dispositivo, macOS la etiqueta con el nombre de la app, así que la barra lateral dice Ferry. Es normal.

### Copiar archivos

Arrastra archivos o carpetas entre el dispositivo y la Mac para copiarlos. Un archivo copiado a medias nunca aparece con su nombre real.

Finder muestra cuánto lleva cada copia, y el menú de Ferry enumera las copias en curso bajo su dispositivo.

Los archivos de más de 4 GB se copian al almacenamiento interno. Muchas tarjetas SD no pueden contener un archivo de más de 4 GB; Ferry muestra un error en lugar de copiar una parte.

Un paquete, como un documento .rtfd o una app, no se puede copiar al dispositivo: comprímelo primero en un .zip. Tampoco se pueden copiar al dispositivo los enlaces simbólicos ni los alias; Finder muestra un error para ellos.

Si el dispositivo se desconecta durante una copia, vuelve a conectarlo y activa la transferencia de archivos. Finder termina la copia cuando el dispositivo se reconecta.

### Renombrar y eliminar

Renombra archivos y crea carpetas en el dispositivo como en cualquier disco.

El dispositivo no tiene Papelera. Finder ofrece **Eliminar inmediatamente**, y el archivo se elimina del dispositivo al instante.

Una carpeta se elimina con su contenido solo si Finder ha mostrado todo lo que hay en ella, en todos los niveles, tal como está ahora. Si algo dentro es nuevo o ha cambiado en el dispositivo, o una carpeta interior nunca se abrió, la carpeta completa permanece y Finder la restaura. Vuelve a eliminarla para quitarla. Una carpeta anidada a más de 64 niveles de profundidad, o que contenga más de 100,000 ítems, también permanece. Una carpeta que contiene un archivo cuyo nombre la Mac no puede mostrar también permanece; elimínala en el dispositivo.

Un archivo que el dispositivo cambió desde la última vez que Finder lo mostró no se elimina. Finder lo restaura con la versión del dispositivo.

#### Carpetas con nombre de app

Una carpeta del dispositivo con nombre de app o de paquete de documento, como Tool.app o Notes.rtfd, se muestra en Finder como una app o un documento, porque macOS se guía por el nombre. Las carpetas de apps del propio Android también cuentan: Android/data/com.example.app se ve como una app. Es de solo lectura en la Mac, con todo lo que contiene: edítala en el dispositivo o cópiala a la Mac. Lo que se ponga dentro de una se queda en la Mac, y Finder muestra un error para ello. Guardar una desde una app de la Mac puede dejar una copia a su lado, como Notes 2.rtfd, que Finder marca con un error, con la edición solo en la Mac: cópiala a la Mac para conservarla. Una carpeta no se puede renombrar con un nombre así. Para quitar una, elimínala en el dispositivo o elimina la carpeta que la contiene; Finder puede restaurar esa carpeta una vez, así que vuelve a eliminarla.

### Cuando un archivo cambió en ambos lados

Si un archivo cambió en el dispositivo después de que la Mac lo leyó, Ferry conserva la versión del dispositivo y guarda la tuya a su lado como **nombre (conflicto desde la Mac)**.

Ferry nunca reemplaza un archivo que el dispositivo cambió sin que lo veas.

### Ver los cambios hechos en el dispositivo

La rapidez con que Finder muestra un cambio hecho en el dispositivo depende de cómo llega Ferry a él.

Ferry vigila las 32 carpetas que Finder mostró más recientemente en cada dispositivo. Un cambio en una carpeta que no has abierto aparece cuando la abres. Mientras se ejecuta una copia hacia o desde el dispositivo, Ferry vuelve a buscar cambios cuando termina.

Para ahorrar batería, Ferry deja de comprobar cada 30 segundos cuando nada ha usado el dispositivo durante unos 10 minutos, aunque una ventana de Finder todavía lo muestre. A partir de entonces, un cambio hecho en el dispositivo puede esperar hasta que abras una carpeta en él o hagas clic en **Actualizar** en el menú de Ferry. Con la depuración por USB o por Wi-Fi, el dispositivo sigue informando de la mayoría de los cambios por sí mismo.

- **Depuración por USB o Wi-Fi**: Los cambios aparecen en Finder en unos segundos. Mientras usas el dispositivo en Finder, Ferry también comprueba cada 30 segundos si se le escapó alguno.
- **Transferencia de archivos**: Mientras usas el dispositivo en Finder, los archivos nuevos y eliminados aparecen en unos 30 segundos. Tras unos 10 minutos sin uso, esperan hasta que abras una carpeta o hagas clic en **Actualizar**. Un archivo modificado en el lugar o renombrado en el dispositivo necesita **Actualizar**.

**Actualizar** en el menú de Ferry (⌘R con el menú abierto) muestra todos los cambios de inmediato.

### Enviar archivos desde Finder

Haz clic con la tecla Control presionada en archivos de la Mac y elige **Enviar a** y el dispositivo. Ferry los copia en la carpeta Download del almacenamiento interno del dispositivo. El botón de Ferry en la barra de herramientas de Finder tiene el mismo menú una vez que lo agregas con **Visualización** → **Personalizar barra de herramientas**.

Si Download ya tiene un archivo con el mismo nombre, Ferry lo conserva y guarda el tuyo a su lado como **nombre (conflicto desde la Mac)**. Enviar nunca reemplaza un archivo.

Cuando todos los archivos seleccionados son .apk y Ferry llega al dispositivo por ADB (con la depuración por USB activada, o por Wi-Fi), el menú también tiene **Instalar en** el dispositivo, que instala las apps como lo hace Instalar app….

Una notificación indica cuándo los archivos están en el dispositivo o la app está instalada, o por qué no.

#### Activar Enviar a

1. Para activar este menú, abre Ajustes del Sistema y luego **General** → **Ítems de inicio y extensiones**.
2. En Extensiones, busca la extensión de Finder de Ferry y actívala.

### Libera espacio en la Mac

Haz clic con la tecla Control presionada en un archivo que abriste y elige **Eliminar descarga**. El archivo permanece en el dispositivo.

## El menú

### Leer el menú

El menú tiene un encabezado con **Actualizar**, luego cualquier problema que requiera tu atención, luego tus dispositivos, luego **Conectar por dirección…** y **Vincular con código…**, luego **Abrir al iniciar sesión**, **Buscar actualizaciones…**, **Ayuda** y **Salir de Ferry**.

Cada dispositivo aparece cerrado cada vez que se abre el menú. Haz clic en un dispositivo para ver sus detalles y lo que puedes hacer con él, y haz clic de nuevo para cerrarlo. Solo hay un dispositivo abierto a la vez, y permanece abierto mientras el menú lo está.

- **Listo**: El dispositivo está compartiendo archivos y está en Finder. Bajo su nombre, el menú muestra cómo llega Ferry a él y el espacio libre, como USB · 21 GB libres, o su dirección por Wi-Fi.
- **Sin compartir archivos**: La transferencia de archivos está desactivada o el dispositivo está bloqueado. Elige **Transferir archivos** en el dispositivo y luego **Actualizar**.
- **Esperando permiso**: La depuración por USB está activada, pero esta Mac aún no está permitida. Toca **Aceptar** o **Permitir** en el dispositivo.
- **Expulsado**: Expulsaste el dispositivo. Permanece fuera de Finder hasta que hagas clic en **Montar**, elijas **Actualizar** o lo desconectes y lo vuelvas a conectar.
- **En uso por otra app**: Otra app tiene el dispositivo. Cierra esa app y luego haz clic en **Volver a comprobar**.
- **No se puede abrir**: El dispositivo informó un error. Haz clic en **Volver a comprobar** o desconéctalo y vuelve a conectarlo.
- **Comprobando…**: Ferry está esperando a que su asistente responda, por ejemplo justo después de abrir Ferry.
- **Recordado · no está cerca**: Un dispositivo que Ferry conecta por la red y al que ahora no puede llegar.

#### Ítems del menú

- **Actualizar**: Presiona ⌘R con el menú abierto. Muestra en Finder todos los cambios hechos en el dispositivo de inmediato, incluidos los archivos modificados en el lugar o renombrados en el modo de transferencia de archivos, monta todos los dispositivos que expulsaste y vuelve a comprobar un dispositivo que no está compartiendo archivos. Mientras el menú está abierto, Ferry también busca dispositivos cada 2 segundos.
- **Abrir al iniciar sesión**: Inicia Ferry cuando inicias sesión. Una marca indica que está activado. **Requiere aprobación en Ajustes del Sistema** significa que macOS está esperando que lo permitas allí.
- **Buscar actualizaciones…**: Busca ahora un Ferry más reciente. Ferry también busca una vez al día por sí mismo. Consulta **Actualizaciones**.
- **Ayuda**: Abre esta ventana. Presiona ⌘? con el menú abierto. Aquí, ⌘F va al campo de búsqueda, Retorno abre la mejor coincidencia, y ⌘[ y ⌘] recorren los temas. Un **?** junto a un problema en el menú abre su entrada aquí.
- **Salir de Ferry**: Cierra el menú. El asistente sigue en ejecución, así que los dispositivos permanecen en Finder.

### Detalles del dispositivo y direcciones

Un dispositivo abierto enumera sus puertos de red con sus direcciones IPv4, y luego su versión de Android y la batería, como Android 8.1.0 · Batería 87%. Para un modelo que Ferry conoce, cada puerto se enumera con el nombre que tiene en la unidad, con No conectado para el que no tiene dirección. Ferry solo los lee, cuando abres el dispositivo y cada 10 segundos mientras el menú permanece abierto.

Haz clic en una dirección para copiarla; la línea muestra Copiado por un momento. Haz clic con la tecla Opción presionada en una dirección para copiar todo lo que informa el dispositivo: modelo, versión de Android, compilación, número de serie, batería, todas las direcciones de todos los puertos, incluida IPv6, y almacenamiento. La línea muestra Todo copiado por un momento.

Los detalles requieren depuración por USB o Wi-Fi.

### Herramientas del dispositivo

Bajo un dispositivo abierto, sus herramientas aparecen en grupos separados por líneas finas. Un dispositivo en transferencia de archivos muestra Más herramientas con depuración por USB… en lugar de las herramientas de ADB.

- **Tomar captura de pantalla, Grabar pantalla**: Capturan la pantalla del dispositivo.
- **Enviar archivo…, Instalar app…**: Copian archivos en Download o instalan una app.
- **Logcat, Reenvío de puertos, Abrir en Terminal**: Herramientas para desarrolladores.
- **Usar por Wi-Fi, Olvidar este dispositivo, Expulsar**: Conexión y Finder.

#### Filas que dependen del estado

- **Expulsar**: Quita un dispositivo listo de Finder y lo libera; luego muestra **Expulsado**. Los cambios que no habían llegado al dispositivo se guardan en una carpeta de la Mac, y el menú ofrece **Mostrar en Finder**. Las eliminaciones y los cambios de nombre que no habían llegado al dispositivo se descartan, así que el dispositivo conserva esos archivos con sus nombres anteriores.
- **Montar**: Para un dispositivo expulsado: lo vuelve a poner en Finder.
- **Volver a comprobar**: Para un dispositivo en uso por otra app o que no se puede abrir: lo intenta de nuevo.
- **Cómo activar la transferencia de archivos**: Para un dispositivo que no comparte archivos: abre los pasos correspondientes.
- **Más herramientas con depuración por USB…**: Abre los pasos para activar la depuración por USB.

### Tomar una captura de pantalla o grabar la pantalla

Haz clic en **Tomar captura de pantalla** para guardar lo que muestra la pantalla del dispositivo. Haz clic en **Grabar pantalla** para grabarla, hasta tres minutos; el menú muestra cuánto lleva grabando, y **Detener grabación** la termina.

Ferry enciende la pantalla del dispositivo antes de una captura o una grabación, así que una pantalla apagada no se captura en negro. Una grabación de una pantalla que no cambia tiene un solo fotograma.

Ferry las guarda en Documentos, en Ferry, y luego en una carpeta por dispositivo con Screenshots y Screen Recordings dentro, con nombres como los de macOS, por ejemplo Captura de pantalla LinkRunner-100G 2026-11-18 a las 17.09.27.png, y las muestra en Finder. macOS pregunta si Ferry puede usar Documentos la primera vez que guarda una. Nunca reemplaza un archivo. Una grabación espera en el dispositivo hasta que Ferry la haya guardado, aunque salgas de Ferry mientras tanto; después Ferry la elimina del dispositivo.

Si Ferry no puede guardar una grabación, el menú muestra No se pudo guardar la grabación: Elegir carpeta… la guarda donde elijas, y Descartar la elimina del dispositivo. Grabar pantalla vuelve a estar disponible una vez que se guarda o se descarta. Un dispositivo expulsado conserva su grabación hasta que Ferry lo sirva de nuevo.

### Instalar una app

Haz clic en Instalar app… y elige un archivo .apk, o arrastra un .apk al dispositivo en el menú. Ferry comprueba que el archivo sea una app de Android, lo copia al dispositivo y lo instala, reemplazando una versión anterior de la misma app. El menú muestra cuánto lleva la copia y luego indica cuándo la app está instalada.

Haz clic en **Cancelar** para detener el proceso mientras la app aún se está copiando. Una vez que el dispositivo la está instalando, la instalación termina.

Si el dispositivo rechaza la app, el menú dice por qué, por ejemplo que hay una versión más reciente instalada o que la app necesita una versión más reciente de Android. Ferry elimina su copia de la app del dispositivo de todos modos.

### Enviar un archivo desde el menú

Haz clic en **Enviar archivo…** bajo un dispositivo y elige archivos. Ferry los copia en la carpeta Download del dispositivo, igual que **Enviar a** en Finder.

El menú indica cuándo están ahí, o por qué no.

### Mira el registro del dispositivo

Haz clic en Logcat para ver el registro del dispositivo en una ventana propia. Ferry conserva las últimas 50,000 líneas. Nivel muestra las líneas de ese nivel y superiores, y Filtrar muestra las líneas que contienen tu texto, sin importar mayúsculas o minúsculas. Pausar congela la ventana mientras siguen llegando líneas, y Reanudar se pone al día. Borrar la vacía.

Guardar… escribe las líneas que coinciden con los filtros en un archivo de texto sin formato donde tú elijas. El registro se detiene cuando cierras la ventana o el dispositivo desaparece.

### Reenviar un puerto

El reenvío de puertos envía las conexiones a un puerto de esta Mac a un puerto del dispositivo.

Si el puerto de esta Mac ya está en uso, el mensaje de adb aparece bajo los puertos. Ferry solo muestra los reenvíos TCP que adb mantiene para este dispositivo.

1. Haz clic en **Reenvío de puertos** bajo el dispositivo. Se abre en el mismo lugar y muestra cada reenvío como Mac 8080 → Dispositivo 80.
2. Escribe el puerto de esta Mac (1024 o superior) y el puerto del dispositivo.
3. Haz clic en **Agregar** o presiona Retorno.

El botón de quitar junto a un reenvío lo termina.

### Abrir un shell en Terminal

Haz clic en Abrir en Terminal para abrir en Terminal un shell del dispositivo (adb shell). Para esto Ferry necesita adb, y lo indica si no lo encuentra. El shell usa el adb que inició el servidor de adb en ejecución cuando Ferry puede saber cuál es, así que no reinicia el servidor de otra herramienta. Nada cambia en el dispositivo a menos que escribas un comando que lo cambie.

## Solución de problemas

### El dispositivo no aparece

1. Prueba con otro cable. Algunos solo transmiten energía.
2. Desbloquea el dispositivo.
3. Activa la transferencia de archivos en el dispositivo.
4. Comprueba que Ferry esté activado en Proveedores de archivos, dentro de Ítems de inicio y extensiones.
5. Elige **Actualizar** en el menú de Ferry.

En la app, **Cómo activar la transferencia de archivos** abre la guía de configuración.

#### Una app o script del dispositivo no se abre de inmediato

Los archivos copiados desde un dispositivo, y las carpetas del dispositivo con nombre de app o de paquete de documento, se marcan como descargados, así que macOS revisa una app o script con Gatekeeper antes de abrirlo por primera vez, igual que con uno descargado de internet.

### Mensajes del dispositivo

Lo que dice el menú sobre un dispositivo conectado y qué hacer.

**No hay ningún dispositivo conectado**

No hay ningún dispositivo conectado que comparta archivos.

Conecta el dispositivo y elige **Transferir archivos** en él.

**Elige Transferir archivos en el dispositivo.**

El dispositivo está conectado pero no comparte archivos, o ningún dispositivo ha compartido archivos todavía.

Desbloquea el dispositivo y elige **Transferir archivos** en él.

**Sin compartir archivos**

La transferencia de archivos está desactivada o el dispositivo está bloqueado.

Desbloquea el dispositivo y elige **Transferir archivos** en él, y luego elige **Actualizar**. No hace falta volver a conectar el cable.

**El dispositivo no está compartiendo archivos. Desbloquéalo, elige Transferir archivos e inténtalo de nuevo.**

El dispositivo se bloqueó o desactivó la transferencia de archivos durante la tarea.

Desbloquea el dispositivo y elige **Transferir archivos** en él, y luego inténtalo de nuevo.

**El dispositivo se desconectó. Vuelve a conectarlo e inténtalo de nuevo.**

El dispositivo desapareció durante la tarea: se desconectó el cable, entró en reposo o salió de la red.

Vuelve a conectar el dispositivo e inténtalo de nuevo.

**El dispositivo no muestra ningún almacenamiento. Desbloquéalo e inténtalo de nuevo.**

El dispositivo no comparte almacenamiento, lo que ocurre mientras está bloqueado.

Desbloquea el dispositivo y elige **Actualizar**, y luego inténtalo de nuevo.

**Ferry no puede hacer esto desde la Mac en este dispositivo. Hazlo en el dispositivo.**

El dispositivo no ofrece lo que se pidió, como mover un archivo en un solo paso, o Ferry no puede hacerlo desde la Mac.

Hazlo en el propio dispositivo, o copia el archivo a su nuevo lugar y elimina el original.

**Ferry no pudo terminar esto. Inténtalo de nuevo; si sigue fallando, vuelve a conectar el dispositivo o vuelve a abrir Ferry.**

Falló a mitad de la tarea la conexión con el dispositivo, un archivo de esta Mac o el asistente de Ferry.

Inténtalo de nuevo. Si sigue fallando, conecta el dispositivo directamente a la Mac y mantenlo desbloqueado, comprueba que la Mac tenga espacio libre, o sal de Ferry y ábrelo de nuevo. Una copia en Finder se reintenta sola cuando el dispositivo vuelve.

**Ese ítem ya no está en el dispositivo. Actualiza e inténtalo de nuevo.**

Alguien eliminó o movió el ítem en el dispositivo, u otra app lo hizo.

Elige **Actualizar** para el dispositivo y busca el ítem donde está ahora.

**El dispositivo ya tiene un ítem con ese nombre. Cámbiale el nombre a uno e inténtalo de nuevo.**

Ya hay un ítem con el mismo nombre en esa carpeta del dispositivo.

Cambia el nombre del ítem en la Mac o en el dispositivo, y luego inténtalo de nuevo.

**El dispositivo no puede guardar ese nombre. Elige otro nombre.**

El nombre tiene caracteres que el almacenamiento del dispositivo no admite, como : * ? " < > | o un punto al final.

Cambia el nombre del ítem usando letras, dígitos, espacios, guiones y puntos, y luego inténtalo de nuevo.

**El dispositivo se quedó sin espacio. Libera espacio en él e inténtalo de nuevo.**

El almacenamiento del dispositivo no tiene espacio para el archivo.

Elimina en el dispositivo los archivos que ya no necesites, o copia en otro almacenamiento, como su tarjeta SD.

**El archivo es demasiado grande para ese almacenamiento. Usa el almacenamiento interno o un archivo más pequeño.**

Las tarjetas con formato FAT32 admiten archivos de hasta 4 GB.

Copia el archivo en el almacenamiento interno del dispositivo, o divídelo en archivos más pequeños.

**El archivo no llegó completo. Inténtalo de nuevo.**

El dispositivo guardó o envió una cantidad de bytes distinta a la del archivo, así que la copia no está completa.

Inténtalo de nuevo. Si sigue ocurriendo, elige **Actualizar** y copia el archivo otra vez.

**El dispositivo guardó el archivo con otro nombre. Búscalo en la carpeta.**

El dispositivo cambió el nombre, por ejemplo porque su almacenamiento no admite algunos caracteres.

Busca el archivo en la carpeta con su nuevo nombre y cámbialo si quieres.

**La carpeta no está vacía. Elimina primero lo que contiene.**

Llegó algo a la carpeta del dispositivo mientras se eliminaba.

Abre la carpeta, elimina lo que contiene y luego elimina la carpeta.

**El archivo cambió en el dispositivo. Actualiza e inténtalo de nuevo.**

La copia del archivo en el dispositivo cambió desde la última vez que la Mac la leyó.

Elige **Actualizar**, revisa qué copia quieres e inténtalo de nuevo.

**Esta Mac se quedó sin espacio. Libera espacio e inténtalo de nuevo.**

El disco de la Mac no tiene espacio para una copia del archivo.

Libera espacio en la Mac (consulta **Libera espacio en la Mac**) e inténtalo de nuevo.

**Esa carpeta está anidada a demasiada profundidad para eliminarla desde la Mac. Elimínala en el dispositivo.**

La carpeta contiene carpetas a más de 64 niveles de profundidad, que Ferry no elimina.

Elimina la carpeta en el propio dispositivo.

**Ese ítem es de solo lectura desde la Mac. Cámbialo en el dispositivo.**

El ítem es una carpeta con nombre de app o de paquete de documento, o está dentro de una, y Ferry la mantiene de solo lectura.

Cámbialo en el dispositivo, o cópialo a la Mac.

**La lista de la carpeta quedó desactualizada. Inténtalo de nuevo.**

El asistente de Ferry se reinició, o se abrieron muchas carpetas, mientras Finder aún leía una carpeta grande.

Abre la carpeta otra vez. Finder la lee desde el principio.

**En uso por otra app**

Otra app de la Mac tiene abierto el dispositivo, así que Ferry no puede acceder a él.

Sal de Captura de Imagen, Vista Previa, Android File Transfer, MacDroid u OpenMTP, y luego haz clic en **Volver a comprobar**.

**Sal de Captura de Imagen o de Android File Transfer, y luego inténtalo de nuevo.**

Otra app de la Mac tiene abierto el dispositivo.

Sal de Captura de Imagen, Vista Previa, Android File Transfer, MacDroid u OpenMTP, y luego haz clic en **Volver a comprobar**.

**Otra app está usando el dispositivo. Sal de Captura de Imagen o de Android File Transfer.**

Otra app de la Mac tiene abierto el dispositivo, así que Ferry no puede acceder a él.

Sal de Captura de Imagen, Vista Previa, Android File Transfer, MacDroid u OpenMTP, y luego haz clic en **Volver a comprobar**.

**No se puede abrir**

El dispositivo informó un error cuando Ferry lo abrió.

Haz clic en **Volver a comprobar**, o desconecta el dispositivo y vuelve a conectarlo.

**Cancelado.**

La tarea se detuvo antes de terminar, normalmente porque la cancelaste.

Inicia la tarea de nuevo si todavía la necesitas.

**Ferry no puede vigilar USB para detectar dispositivos, así que los busca cada 30 segundos.**

macOS no permitió que Ferry vigilara la conexión de dispositivos.

No hay nada que hacer: los dispositivos siguen apareciendo, un poco más tarde. Reinicia la Mac si sigue igual.

**Los cambios sin enviar se guardaron en …**

Expulsaste el dispositivo antes de que algunos cambios llegaran a él. macOS conservó esos archivos en una carpeta de la Mac. Las eliminaciones y los cambios de nombre que no habían llegado al dispositivo se descartaron.

Haz clic en **Mostrar en Finder** y luego copia los archivos de vuelta al dispositivo cuando se monte de nuevo.

**Archivos que esperan volver a su dispositivo: …**

Se estaba reemplazando un archivo en un dispositivo cuando se detuvo la transferencia, antes de que Ferry pudiera devolver el original. Ferry guarda el original en la Mac y lo devuelve la próxima vez que llega al mismo dispositivo y muestra esa carpeta.

Vuelve a conectar el dispositivo y abre la carpeta del archivo en Finder; la línea desaparece cuando los originales han vuelto. Un archivo que Ferry no puede devolver con seguridad aparece en **Los cambios sin enviar se guardaron en …**, para que lo copies tú.

**…: hay cambios pendientes. Vuelve a conectarlo para terminar.**

El dispositivo desapareció, o Ferry ya no puede acceder a él, antes de que algunos cambios llegaran a él. Su ubicación salió de Finder, así que los archivos pendientes no se muestran ahí. Siguen en la Mac. Una tarjeta SD tiene una ubicación para cada forma en que Ferry accede al dispositivo, así que los cambios hechos en la tarjeta por cable esperan al cable, aunque la tarjeta se muestre por la red.

Vuelve a conectar el dispositivo de la misma manera que antes, por cable o por la red. Su ubicación vuelve a Finder y los cambios se envían; la línea desaparece cuando se han enviado.

### Mensajes de depuración por USB

Mensajes sobre ADB, adb y cómo permitir esta Mac.

**Esperando permiso**

La depuración por USB está activada, pero esta Mac aún no tiene permiso en el dispositivo.

Desbloquea el dispositivo, marca **Permitir siempre desde esta computadora** y toca **Aceptar** o **Permitir**.

**Permite la depuración por USB en el dispositivo**

El dispositivo está preguntando si permite esta Mac.

Desbloquea el dispositivo, marca **Permitir siempre desde esta computadora** y toca **Aceptar** o **Permitir**.

**Desconecta el cable y vuelve a conectarlo para usar la depuración por USB**

adb muestra el dispositivo como sin conexión por USB. Esto ocurre cuando la primera lectura de adb desde el dispositivo falla al iniciarse su servidor. Ferry pidió a adb que volviera a conectar el dispositivo, y sigue sin conexión.

Desconecta el cable USB del dispositivo o de la Mac, espera un momento y vuelve a conectarlo. Mientras tanto, la transferencia de archivos sigue funcionando.

**adb no está en esta Mac**

Ferry no encontró adb, así que solo puede usar la transferencia de archivos.

Haz clic en **Obtener Android Platform Tools…** y acepta la licencia de Google: Ferry descarga adb una sola vez. Instalar adb de cualquier otra forma también sirve, por ejemplo android-platform-tools de Homebrew, que descarga el mismo archivo de Google, y Ferry detecta por su cuenta un adb instalado. Si hay ambos, Ferry prefiere su propia copia y nunca interrumpe un servidor de adb en ejecución.

**No se pudo descargar adb. Ferry necesita conexión a internet una vez.**

Ferry no pudo acceder al servidor de descargas de Google, o el servidor no envió el archivo.

Conéctate a internet y haz clic en **Reintentar**. Sin conexión, instala adb de otra forma, por ejemplo con Homebrew: Ferry detecta por su cuenta un adb instalado.

**La descarga no pasó las comprobaciones de Ferry, así que Ferry la eliminó.**

El archivo no era la versión que Ferry espera, no se pudo leer, o su adb no estaba firmado por Google. Ferry nunca ejecuta un adb que no ha comprobado.

Haz clic en **Reintentar**. Si falla otra vez, algo en tu red puede estar modificando las descargas: prueba con otra red.

**Ferry no pudo guardar adb en su carpeta.**

Ferry no pudo escribir en ~/Library/Application Support/Ferry/platform-tools: la Mac puede estar llena, o la carpeta puede estar bloqueada o pertenecer a otro usuario.

Libera espacio en la Mac, o elimina esa carpeta si pertenece a otro usuario, y luego haz clic en **Reintentar**.

**Google cambió la Android SDK License**

Ferry muestra un texto de la licencia de Google más reciente que el que aceptaste. Ferry sigue usando el adb que tiene hasta que la aceptes.

Haz clic en **Revisar licencia…** y acéptala. Si esta versión de Ferry necesita un adb más reciente, Ferry lo descarga después.

**adb no se está ejecutando**

adb está instalado, pero su servidor no responde.

Haz clic en **Volver a comprobar**. Si no ayuda, sal de otras apps que usen adb, como Android Studio, y luego haz clic en **Volver a comprobar**.

**Esto requiere depuración por USB. Actívala e inténtalo de nuevo.**

Esta herramienta solo funciona con ADB, y el dispositivo está en transferencia de archivos.

Activa la depuración por USB en el dispositivo e inténtalo de nuevo.

**Ferry no encuentra adb. Obtenlo desde el menú de Ferry e inténtalo de nuevo.**

Esta herramienta ejecuta adb, y Ferry no lo encuentra en esta Mac.

En el menú de Ferry, haz clic en **Obtener Android Platform Tools…** e inténtalo de nuevo.

**Ferry no pudo abrir Terminal.**

macOS no permitió que Ferry abriera Terminal, o falta Terminal.

Abre Terminal una vez por tu cuenta e inténtalo de nuevo. Si macOS pregunta si Ferry puede controlar Terminal, permítelo.

**Ferry no pudo saber qué adb inició el servidor de adb, así que esto usa el adb propio de Ferry. Si su versión es distinta, adb puede reiniciar el servidor.**

Abrir en Terminal ejecuta el adb que inició el servidor de adb en ejecución, para que ambos coincidan siempre. Ferry no pudo leer qué programa es, así que el shell ejecuta el adb que Ferry encontró: su propia copia, o una que ya estaba en esta Mac, indicada en el mensaje.

Nada, si el shell se abre. Si otra herramienta, como Android Studio, pierde sus dispositivos, cierra el shell y ejecuta adb shell con el adb de esa herramienta.

**Ferry no pudo saber qué adb inició el servidor de adb, así que esto usa el adb de …. Si su versión es distinta, adb puede reiniciar el servidor.**

Abrir en Terminal ejecuta el adb que inició el servidor de adb en ejecución, para que ambos coincidan siempre. Ferry no pudo leer qué programa es, así que el shell ejecuta el adb que Ferry encontró: su propia copia, o una que ya estaba en esta Mac, indicada en el mensaje.

Nada, si el shell se abre. Si otra herramienta, como Android Studio, pierde sus dispositivos, cierra el shell y ejecuta adb shell con el adb de esa herramienta.

### Mensajes de Wi-Fi y de red

Mensajes de Usar por Wi-Fi, Conectar por dirección, Vincular con código y dispositivos recordados.

**Esperando a que permitas esta Mac en …**

Un dispositivo de tu red está preguntando si permite esta Mac.

Toca **Permitir** en el dispositivo.

**Toca Permitir en el dispositivo para terminar de conectar.**

El dispositivo respondió y está preguntando si permite esta Mac.

Toca **Permitir** en el dispositivo.

**Ferry conoce este dispositivo con otra dirección. Confirma la nueva en el menú.**

Una dirección nueva respondió como un dispositivo que Ferry ya conoce, y Ferry no la usará hasta que tú lo indiques.

Haz clic en la dirección en el menú y elige **Usar** si es tu dispositivo, o **Ignorar**.

**El dispositivo no tiene dirección de red. Conéctalo primero a Ethernet o Wi-Fi.**

El dispositivo no está en Ethernet ni en Wi-Fi.

Conecta el dispositivo a Ethernet o Wi-Fi y haz clic en **Usar por Wi-Fi** de nuevo.

**adb no está disponible. Usa la línea de adb en la parte superior del menú.**

Las conexiones de red necesitan adb, y Ferry no tiene ninguno o su servidor no responde.

Haz clic en **Obtener Android Platform Tools…** o en **Volver a comprobar** en la parte superior del menú, y luego inténtalo de nuevo.

**Conecta primero el dispositivo con un cable y permite la depuración por USB.**

Usar por Wi-Fi parte de un dispositivo que Ferry sirve mediante la depuración por USB.

Conecta el dispositivo con un cable, permite esta Mac en él e inténtalo de nuevo.

**Ferry no tiene una dirección para este dispositivo. Conéctalo por dirección.**

Ferry nunca ha accedido a este dispositivo por la red.

Haz clic en **Conectar por dirección…** y escribe su dirección.

**Vinculado, pero el dispositivo no ofrece una conexión. Comprueba que la depuración inalámbrica esté activada.**

La vinculación funcionó, pero el dispositivo dejó de ofrecer una conexión, normalmente porque la depuración inalámbrica se desactivó.

En el dispositivo, activa la **Depuración inalámbrica** y luego haz clic en **Volver a conectar**.

**Esa dirección pertenece a otro dispositivo.**

La dirección respondió como un dispositivo distinto del que elegiste.

Comprueba la dirección en el dispositivo e inténtalo de nuevo.

**El dispositivo no indicó cuál es, así que Ferry lo desconectó.**

El dispositivo respondió sin número de serie, así que Ferry no pudo distinguirlo de otros.

Conecta el dispositivo por cable una vez e inténtalo de nuevo.

**Usa la dirección IP que muestra el dispositivo en Vincular dispositivo con código de vinculación.**

La vinculación necesita la dirección de la pantalla de vinculación, que tiene su propio puerto.

Copia la dirección IP y el puerto de **Vincular dispositivo con código de vinculación** en el dispositivo.

**Esa dirección cambió. Revisa el menú e inténtalo de nuevo.**

La dirección cambió después de que el menú la mostrara.

Abre el menú de nuevo y elige entre lo que muestra ahora.

**adb había perdido el acceso a la red, así que Ferry lo reinició. Inténtalo de nuevo en un momento.**

El servidor de adb lo había iniciado una copia anterior del asistente de Ferry. Cuando ese asistente se cerró, macOS cortó el servidor de tu red, y adb dijo "No route to host".

No hay nada que cambiar: Ferry reinicia adb por sí mismo y vuelve a conectar tus dispositivos. Si este no vuelve en unos segundos, haz clic en **Volver a conectar**.

**Ferry necesita acceso a la Red local para llegar a los dispositivos por Wi-Fi. Activa FerryAgent (Ferry) en Ajustes del Sistema › Privacidad y seguridad › Red local.**

macOS pregunta antes de que una app acceda a los dispositivos de tu red. FerryAgent, el asistente de Ferry, no tenía permiso, así que macOS lo bloquea, y adb informa "No route to host" aunque el dispositivo responda.

Abre Ajustes del Sistema › **Privacidad y seguridad** › **Red local**, activa **FerryAgent** y luego haz clic en **Volver a conectar**. Si FerryAgent no aparece, conecta una vez más y haz clic en **Permitir** cuando macOS lo pregunte.

**Ferry está usando este dispositivo. Espera a que terminen sus transferencias, la grabación de pantalla y el registro, y luego inténtalo de nuevo.**

Activar ADB por Wi-Fi reinicia ADB en el dispositivo, lo que detendría una transferencia, una grabación de pantalla o un registro.

Deja que terminen e inténtalo de nuevo.

**adb rechazó la solicitud. Comprueba la dirección y que el dispositivo esté en la red, y luego inténtalo de nuevo. (…)**

adb rechazó la solicitud. El resto del mensaje es el motivo de adb.

Comprueba la dirección y que el dispositivo esté en la red, y luego inténtalo de nuevo.

**Recordado · no está cerca**

Ferry reconoce el dispositivo, pero ahora no puede acceder a él en la red.

Conecta el dispositivo a la red, haz clic en él en el menú y luego en **Volver a conectar**.

### Mensajes en Finder

Finder muestra estos mensajes cuando no funciona una copia, un cambio de nombre o una eliminación en el dispositivo.

**Conecta el dispositivo y elige Transferir archivos para ver sus archivos.**

Finder muestra esto en la ubicación de un dispositivo mientras el dispositivo no está conectado o no comparte archivos.

Conecta el dispositivo y elige **Transferir archivos** en él.

**Los paquetes de documentos y de apps no se pueden copiar al dispositivo. Primero comprime el paquete en un .zip.**

Un paquete es un solo ítem en la Mac, pero una carpeta en el dispositivo, así que Ferry no lo copia.

Haz clic en él con la tecla Control presionada, elige **Comprimir** y copia el .zip en su lugar.

**Los enlaces simbólicos y los alias no se pueden copiar al dispositivo.**

El dispositivo no tiene enlaces ni alias.

Copia el archivo original en su lugar.

**Una carpeta del dispositivo no puede tener nombre de paquete, como .app o .rtfd: macOS la abriría como una app o un documento.**

macOS mostraría una carpeta con ese nombre como una app o un documento.

Elige un nombre sin extensión de paquete, como .app o .rtfd.

**Las carpetas con nombre de app o de paquete de documento, y lo que contienen, no se pueden cambiar desde esta Mac. Cámbialas en el dispositivo.**

macOS muestra una carpeta así como una app o un documento, por eso Ferry la mantiene de solo lectura.

Cámbialo en el dispositivo, o cópialo a la Mac.

**El dispositivo guardó “…” como “…”.**

El dispositivo cambió el nombre, por ejemplo porque no puede guardar algunos caracteres.

Usa el nombre que eligió el dispositivo o cámbialo por uno con caracteres que el dispositivo acepte.

**El dispositivo envió … bytes de un archivo que figura con … bytes.**

El archivo llegó con un tamaño distinto del que indicó el dispositivo, así que la copia no está completa.

Elige **Actualizar** y vuelve a abrir el archivo.

**El dispositivo guardó … bytes, pero se enviaron ….**

El dispositivo conservó un tamaño distinto del que envió Ferry, así que la copia no está completa.

Comprueba que el dispositivo tenga espacio libre y vuelve a copiar el archivo.

**“…” contiene carpetas anidadas a más de … niveles, que Ferry no elimina.**

Ferry no elimina una carpeta anidada a más de 64 niveles de profundidad.

Elimínala en el dispositivo.

**El asistente de Ferry envió una respuesta que Ferry no esperaba. Sal de Ferry, vuelve a abrirlo e inténtalo de nuevo.**

El asistente de Ferry respondió de una forma que la extensión de Finder no espera, algo que puede ocurrir justo después de una actualización.

Sal de Ferry desde el menú y ábrelo de nuevo desde Aplicaciones.

### Mensajes de Enviar a y Enviar archivo

La notificación o la línea del menú indica qué archivo falló y luego por qué. Busca el motivo también aquí.

**No se pudo enviar “…” a …**

El archivo no llegó al dispositivo. La línea siguiente explica por qué.

Corrige lo que indica la línea siguiente y vuelve a enviarlo.

**No se pudieron enviar … archivos a …**

Ninguno de los archivos llegó al dispositivo. La línea siguiente explica por qué en uno de ellos.

Corrige lo que indica la línea siguiente y vuelve a enviarlos.

**Se enviaron … de … a …**

Algunos archivos llegaron al dispositivo y otros no. La línea siguiente nombra uno que no llegó y explica por qué.

Corrige lo que indica la línea siguiente y vuelve a enviar el resto.

**“…” no se envió.**

El archivo mencionado no llegó al dispositivo. A continuación se indica el motivo.

Corrige el motivo y vuelve a enviarlo.

**Tampoco se enviaron: ….**

Fallaron más archivos además del mencionado.

Corrige el motivo indicado y vuelve a enviarlos.

**No se pudo instalar “…” en …**

La app no se instaló. La línea siguiente explica por qué.

Corrige lo que indica la línea siguiente y vuelve a instalarla.

**No se pudieron instalar … apps en …**

Ninguna de las apps se instaló. La línea siguiente explica por qué en una de ellas.

Corrige lo que indica la línea siguiente y vuelve a instalarlas.

**Se instalaron … de … en …**

Algunas apps se instalaron y otras no. La línea siguiente nombra una que no se instaló y explica por qué.

Corrige lo que indica la línea siguiente y vuelve a instalar el resto.

**“…” no se instaló.**

La app mencionada no se instaló. A continuación se indica el motivo.

Corrige el motivo y vuelve a instalarla.

**Tampoco se instalaron: ….**

Fallaron más apps además de la mencionada.

Corrige el motivo indicado y vuelve a instalarlas.

**Solo se pueden enviar archivos.**

Elegiste algo que no es un archivo normal.

Elige archivos. Para copiar una carpeta, arrástrala a la ubicación del dispositivo en Finder.

**Las carpetas no se pueden enviar desde este menú. Copia la carpeta a la ubicación del dispositivo en Finder, o comprímela primero en un .zip.**

Enviar a solo envía archivos.

Arrastra la carpeta a la ubicación del dispositivo en Finder o primero comprímela en un .zip.

**El dispositivo no puede guardar un archivo con ese nombre.**

El nombre tiene caracteres que el almacenamiento del dispositivo no permite.

Cambia el nombre del archivo en la Mac y vuelve a enviarlo.

**El dispositivo no tiene suficiente espacio libre.**

El almacenamiento del dispositivo está lleno.

Libera espacio en el dispositivo e inténtalo de nuevo.

**El dispositivo tiene un archivo llamado Download donde debería estar su carpeta Download. Cámbiale el nombre o elimínalo en el dispositivo e inténtalo de nuevo.**

Ferry envía a Download, y un archivo del dispositivo tiene ese nombre.

Cambia el nombre de ese archivo o elimínalo en el dispositivo e inténtalo de nuevo.

**No se puede leer el archivo.**

Ferry no pudo leer el archivo en la Mac, por ejemplo por sus permisos.

Comprueba que puedas abrir el archivo e inténtalo de nuevo.

**El archivo es demasiado grande para el almacenamiento del dispositivo.**

El almacenamiento no puede contener un archivo tan grande. Muchas tarjetas SD llegan solo hasta 4 GB.

Comprime o divide el archivo, o cópialo en el almacenamiento interno.

**Esta Mac no tiene suficiente espacio libre para copiar el archivo.**

Ferry necesita espacio en la Mac para la copia.

Libera espacio en la Mac e inténtalo de nuevo.

### Mensajes de instalación de apps

Instalar app…, Instalar en y soltar un .apk en un dispositivo pueden terminar con estos mensajes.

**Ese archivo no es una app de Android (.apk).**

El archivo no contiene una app de Android, aunque su nombre termine en .apk.

Elige un archivo .apk real. Una app dividida (.apks o .xapk) no se puede instalar de esta forma.

**Esa app ocupa más de 4 GB.**

Ferry instala apps de hasta 4 GB.

Instálala de otra forma, por ejemplo desde una tienda de apps en el dispositivo.

**La app ya está instalada.**

El dispositivo ya tiene esta app.

No hay nada que hacer. Para reinstalarla, primero desinstálala en el dispositivo.

**Hay una versión más reciente de la app instalada. Desinstálala primero.**

El dispositivo tiene una versión más reciente de esta app que el .apk que elegiste.

Desinstala la app en el dispositivo y vuelve a instalar. O instala un .apk más reciente.

**La app instalada tiene otra firma. Desinstálala primero.**

La app del dispositivo fue firmada por otra persona, así que Android no la reemplazará.

Desinstala la app en el dispositivo y vuelve a instalar. Sus datos en el dispositivo se eliminan con ella.

**La app necesita una versión más reciente de Android.**

La app necesita un Android más reciente que el del dispositivo.

Usa una versión de la app compatible con esta versión de Android.

**La app no es compatible con el procesador de este dispositivo.**

La app está creada para un tipo de procesador distinto del de este dispositivo.

Obtén una versión de la app creada para este dispositivo.

**La app es una compilación de prueba, que el dispositivo no instala.**

La app está marcada como compilación de prueba, que Android instala solo con un comando de desarrollador.

Usa una compilación de lanzamiento de la app.

**Otra app del dispositivo ya define uno de los permisos de esta app.**

Una app que ya está en el dispositivo define un permiso que esta app también define.

Desinstala la otra app y vuelve a instalar.

**Otra app del dispositivo ya usa el proveedor de contenido de esta app.**

Una app que ya está en el dispositivo reclama el mismo proveedor de contenido.

Desinstala la otra app y vuelve a instalar.

**La app necesita una biblioteca que el dispositivo no tiene.**

La app depende de una biblioteca del sistema que a este dispositivo le falta.

Usa una versión de la app hecha para este dispositivo.

**El dispositivo no pudo leer la app. Puede estar dañada o no estar firmada.**

El dispositivo no pudo leer el .apk. Puede estar incompleto, dañado o sin firmar.

Descarga o compila el .apk de nuevo e instálalo.

**El dispositivo no permite instalar apps por USB.**

Un ajuste del dispositivo bloquea las instalaciones mediante USB.

En **Opciones para desarrolladores**, activa **Instalar mediante USB** si el dispositivo la tiene e inténtalo de nuevo.

**La verificación de apps del dispositivo rechazó la app.**

Las comprobaciones de apps del dispositivo bloquearon la app.

Instala apps solo de fuentes de confianza. Los ajustes de seguridad del dispositivo pueden permitirte autorizarla.

**La instalación se canceló en el dispositivo.**

Alguien tocó Cancelar en el dispositivo, o el dispositivo detuvo la instalación.

Vuelve a instalar y acepta el aviso en el dispositivo.

**El dispositivo no tiene suficiente espacio para la app.**

El almacenamiento interno del dispositivo está demasiado lleno para instalar la app.

Libera espacio en el dispositivo e inténtalo de nuevo.

**El dispositivo no instaló la app. Comprueba que sea adecuada para este dispositivo e inténtalo de nuevo. (…)**

El dispositivo rechazó la app por un motivo que Ferry no sabe expresar con palabras sencillas. El resto del mensaje es el motivo del propio dispositivo.

Busca ese motivo o comprueba que la app sea adecuada para este dispositivo.

### Mensajes de capturas de pantalla y grabaciones

Tomar captura de pantalla y Grabar pantalla pueden terminar con estos mensajes.

**El dispositivo no envió una captura de pantalla. Desbloquéalo e inténtalo de nuevo.**

El dispositivo no devolvió ninguna imagen, algo que ocurre mientras está bloqueado.

Desbloquea el dispositivo y haz clic en **Tomar captura de pantalla** otra vez.

**Ferry no puede guardar en su carpeta de Documentos. Permite el acceso a Ferry en Privacidad y seguridad.**

macOS no deja que Ferry escriba en Documentos, donde guarda las capturas de pantalla y las grabaciones.

Abre Ajustes del Sistema → **Privacidad y seguridad** → **Archivos y carpetas** y activa Documentos para Ferry.

**El dispositivo ya está grabando su pantalla.**

Ya hay una grabación en curso en el dispositivo.

Primero haz clic en **Detener grabación**.

**El dispositivo no está grabando su pantalla.**

No hay ninguna grabación en curso, así que no hay nada que detener. Puede que haya llegado a su límite de tres minutos.

Haz clic en **Grabar pantalla** para iniciar una nueva.

**El dispositivo no grabó su pantalla.**

El grabador de pantalla del dispositivo se detuvo sin generar una grabación.

Desbloquea el dispositivo e inténtalo de nuevo.

**El dispositivo no grabó su pantalla: …**

El grabador de pantalla del dispositivo falló. El resto del mensaje es el motivo del propio dispositivo.

Desbloquea el dispositivo e inténtalo de nuevo. Algunas pantallas, como el video protegido, no se pueden grabar.

**El dispositivo envió más de lo que puede ocupar una grabación, así que Ferry la eliminó.**

El archivo que envió el dispositivo era más grande de lo que puede ser una grabación de tres minutos, así que Ferry no lo conservó.

Vuelve a grabar.

**La grabación dejó de llegar. Sigue en el dispositivo: elige una carpeta o descártala.**

La grabación dejó de llegar desde el dispositivo antes de que Ferry la guardara.

Haz clic en **Elegir carpeta…** para guardarla o en **Descartar** para eliminarla del dispositivo.

**La grabación todavía se está terminando. Inténtalo de nuevo en un momento.**

Ferry sigue guardando la última grabación.

Espera a que el menú deje de mostrar **Guardando grabación…** e inténtalo de nuevo.

**No se pudo guardar la grabación**

Ferry no pudo guardar la grabación en Documentos. Sigue en el dispositivo.

Haz clic en **Elegir carpeta…** para guardarla donde elijas o en **Descartar** para eliminarla.

**El asistente de Ferry no pudo empezar a copiar la grabación.**

El asistente de Ferry no pudo crear el archivo donde copiar la grabación.

Comprueba que la Mac tenga espacio libre y haz clic en **Elegir carpeta…** otra vez.

### Mensajes de reenvío de puertos y del registro

**Los puertos de esta Mac empiezan en 1024.**

Los puertos por debajo de 1024 en una Mac requieren permisos de administrador.

Escribe un puerto del 1024 al 65535.

**Usa un puerto de 1024 a 65535 en esta Mac y de 1 a 65535 en el dispositivo.**

Falta uno de los puertos o está fuera de rango.

Escribe un puerto de la Mac del 1024 al 65535 y un puerto del dispositivo del 1 al 65535.

**adb no pudo reenviar el puerto: …**

adb rechazó el reenvío. El resto del mensaje es el motivo de adb. A menudo el puerto de esta Mac ya está en uso.

Elige otro puerto en esta Mac o sal de la app que lo usa.

**Ese reenvío ya no existe.**

adb ya eliminó el reenvío, por ejemplo porque el dispositivo se desconectó.

No hay nada que hacer. Agrégalo de nuevo si lo necesitas.

**El dispositivo terminó el registro.**

El dispositivo dejó de enviar su registro, por ejemplo porque se reinició.

Cierra la ventana y haz clic en **Logcat** otra vez.

**— Líneas omitidas: …. El registro llegó más rápido de lo que Ferry podía mostrarlo. —**

El registro llegó más rápido de lo que Ferry podía mostrarlo, así que se omitieron algunas líneas.

Ajusta **Nivel** o **Filtrar** para mostrar menos líneas.

**Ferry no pudo guardar el registro. Elige otra carpeta o libera espacio e inténtalo de nuevo. (…)**

Ferry no pudo escribir el archivo. El resto del mensaje explica por qué.

Elige otra carpeta o comprueba que haya espacio libre, y haz clic en **Guardar…** otra vez.

### El asistente de Ferry y los ajustes

Mensajes sobre Ferry.

**Activar Ferry en Finder**

Todas las ubicaciones de Ferry están desactivadas en Ajustes del Sistema.

Haz clic en **Abrir Ajustes del Sistema** y activa Ferry en Proveedores de archivos.

**Permite el asistente de Ferry**

macOS no deja que se ejecute el asistente de Ferry.

Haz clic en **Abrir Ajustes del Sistema** y activa Ferry en Permitir en segundo plano.

**macOS no encuentra el asistente de Ferry**

macOS perdió el rastro del asistente de Ferry, a menudo después de mover Ferry.

Haz clic en **Abrir Ajustes del Sistema** y activa Ferry en Permitir en segundo plano. Si no aparece, mueve Ferry a Aplicaciones y ábrelo de nuevo.

**El asistente de Ferry no responde. Sal de Ferry y ábrelo de nuevo.**

El asistente de Ferry dejó de responder.

Sal de Ferry desde el menú y ábrelo de nuevo desde Aplicaciones.

**El asistente de Ferry no respondió a tiempo. Inténtalo de nuevo en un momento.**

El asistente de Ferry está ocupado o bloqueado.

Espera un momento e inténtalo de nuevo. Si sigue pasando, sal de Ferry y ábrelo de nuevo.

**El asistente de Ferry tiene demasiadas solicitudes en espera. Inténtalo de nuevo en un momento.**

El asistente de Ferry recibió más solicitudes a la vez de las que admite, así que rechazó esta.

Espera a que terminen las copias en curso e inténtalo de nuevo. Si sigue pasando, sal de Ferry y ábrelo de nuevo.

**Ferry se actualizó. Sal de Ferry y ábrelo de nuevo.**

Una versión más reciente de Ferry reemplazó a esta mientras se ejecutaba.

Haz clic en **Reabrir**.

**El asistente de Ferry no pudo leer la solicitud.**

El asistente recibió una solicitud que no pudo leer, lo que puede pasar justo después de una actualización.

Sal de Ferry desde el menú y ábrelo de nuevo desde Aplicaciones.

**El asistente de Ferry no acepta esta solicitud desde aquí.**

Una parte de Ferry pidió algo que solo otra parte puede pedir, lo que indica una instalación mezclada o dañada.

Instala Ferry de nuevo y ábrelo.

**No se pudo cambiar Abrir al iniciar sesión.**

macOS no aceptó el cambio.

Inténtalo de nuevo. O abre Ajustes del Sistema → **General** → **Ítems de inicio y extensiones** y cámbialo allí.

**Requiere aprobación en Ajustes del Sistema**

macOS está esperando que permitas que Ferry se abra al iniciar sesión.

Abre Ajustes del Sistema → **General** → **Ítems de inicio y extensiones** y permite Ferry.

**No se pudo eliminar Ferry. Inténtalo de nuevo; si sigue fallando, reinicia la Mac e inténtalo otra vez.**

macOS mantuvo las ubicaciones de Ferry en Finder, o no detuvo el asistente de Ferry.

Haz clic en **Eliminar Ferry…** otra vez. Si sigue fallando, reinicia la Mac, abre Ferry y vuelve a eliminarlo.

**La Ayuda no está disponible**

Falta la ayuda de Ferry en la app.

Instala Ferry de nuevo.

### Diagnóstico para soporte

Cuando pidas ayuda con Ferry, haz clic en **Copiar diagnóstico** y pega el informe en tu mensaje. Va al portapapeles y a ningún otro sitio: Ferry no envía nada.

El informe indica las versiones de Ferry, de su asistente y de macOS; si adb está instalado y su servidor en marcha, y la versión del adb propio de Ferry; el modelo de cada dispositivo conectado, cómo lo alcanza Ferry y su estado; y los últimos errores que mostró el menú, con su redacción general. Omite números de serie, direcciones de red, nombres de archivo y carpetas.

## Acerca de Ferry

### Actualizaciones

Ferry busca una versión nueva una vez al día. Cuando hay una, la descarga en segundo plano y la instala la próxima vez que Ferry se cierre, así nada se detiene mientras trabajas. Cuando ya se ha descargado, el menú de Ferry muestra **Actualización lista — Reiniciar Ferry** en lugar de Buscar actualizaciones…: elígelo para instalar la actualización y volver a abrir Ferry ahora.

Para buscar ahora, elige **Buscar actualizaciones…** en el menú de Ferry. Ferry muestra las novedades de la versión y ofrece instalarla.

Después de una actualización, Ferry reinicia su asistente la primera vez que se abre. Tus dispositivos salen de Finder un momento y vuelven; una copia que estaba en curso se detiene, así que cópiala de nuevo.

Ferry instala una actualización solo si lleva la firma de la clave de versiones de Ferry y una firma de código válida. Las versiones se firman con el Developer ID del desarrollador y Apple las notariza. Ferry lee la lista de versiones de GitHub mediante una conexión segura.

### Privacidad

Ferry no tiene telemetría, ni analíticas, ni cuenta. Tus archivos van solo entre el dispositivo y tu Mac. Si usas ADB por Wi-Fi, Ferry se comunica con ese dispositivo en tu red y con nada más.

Ferry se conecta a internet para dos cosas. Busca actualizaciones a diario en GitHub, donde se publican las versiones de Ferry. Y descarga adb de Google: una vez, cuando aceptas la licencia de Google, y de nuevo sin preguntar cuando una actualización de Ferry necesita un adb más reciente bajo la licencia que aceptaste. Ninguna de las dos envía nada sobre ti ni sobre tus dispositivos: como en cualquier descarga, ven la dirección IP de tu Mac, y GitHub ve qué versiones de Ferry y de su actualizador lo solicitan.

### Eliminar Ferry

Elimina las ubicaciones de Ferry de Finder, detiene el asistente de Ferry, mueve a la Papelera lo que Ferry guarda en esta Mac y sale de Ferry, después de pedirte confirmación. Los archivos de tus dispositivos no se tocan. Úsalo antes de mover Ferry a la Papelera, o para empezar de nuevo desde cero; al empezar de nuevo, adb se vuelve a descargar de Google. Funciona incluso cuando el asistente de Ferry no responde.

Para encontrarlo desde el menú, mantén presionada la tecla Opción con el menú de Ferry abierto: **Salir de Ferry** pasa a ser **Eliminar Ferry…**, que abre esta página.

Cuando el asistente se detiene, Ferry mueve a la Papelera ~/Library/Application Support/Ferry (el adb que descargó y tu aceptación de la licencia de Google) y ~/Library/Application Support/io.github.krisarmstrong.ferry.agent (sus listas de archivos de tus dispositivos y los dispositivos a los que se reconecta por la red), así que puedes recuperarlos si eliminaste Ferry por error. Si el adb propio de Ferry sigue en ejecución, Ferry lo detiene, incluido un shell que abriste desde el menú de Ferry; un adb que instalaste tú se deja intacto. Los cambios que Finder no había enviado a un dispositivo se conservan y se muestran en Finder.

Ferry también olvida que se ejecutó en esta Mac, así que si lo instalas de nuevo, la bienvenida se abre otra vez.

El botón **Eliminar Ferry…** está aquí, en la Ayuda de Ferry. Ferry te pide confirmación primero.

### Desinstalar

1. En la Ayuda de Ferry, en **Acerca de Ferry**, haz clic en **Eliminar Ferry…** y confirma. Tus dispositivos desaparecen de Finder, el asistente de Ferry se detiene, Ferry mueve sus datos de ~/Library/Application Support a la Papelera y Ferry se cierra. Los archivos de tus dispositivos no se tocan.
2. Arrastra Ferry de Aplicaciones a la Papelera.
3. Para eliminar también las preferencias de Ferry, elimina ~/Library/Preferences/io.github.krisarmstrong.ferry.plist y la carpeta de Ferry en ~/Library/Group Containers.

### Agradecimientos

Ferry se publica bajo la licencia MIT. Se basa en el trabajo de otros:

**Sparkle**, que mantiene Ferry actualizado, es © Andy Matuschak y los colaboradores de Sparkle, bajo la licencia MIT. Su licencia, con los avisos de terceros que menciona, está en Ferry.app/Contents/Resources/Licenses/Sparkle-LICENSE.txt.

**libmtp** y **libusb**, que permiten que Ferry se comunique con dispositivos por MTP, están bajo la Licencia Pública General Menor de GNU, versión 2.1. Ferry los incluye sin modificar en Ferry.app/Contents/Frameworks, con sus textos de licencia en Ferry.app/Contents/Resources/Licenses. El código fuente exacto con el que se compiló cada versión está adjunto a esa versión en GitHub, en github.com/krisarmstrong/ferry/releases; Licenses/README.txt nombra cada tarball con su SHA-256.

**adb**, de Android SDK Platform-Tools de Google, no es parte de Ferry. Ferry lo descarga de Google solo después de que aceptas la Android SDK License, que Ferry muestra primero y guarda con la app.

Android es una marca comercial de Google LLC.
