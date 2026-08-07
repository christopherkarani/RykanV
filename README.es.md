<p align="center">
  <img src="docs/images/ryk-banner.svg" alt="ryk, controles para agentes de programación" width="100%">
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ur-pk.md">اردو</a>
</p>

<p align="center">
  <a href="https://rykanv.com/">Sitio web</a> ·
  <a href="https://discord.gg/uZn9MDUYKx">Discord</a> ·
  <a href="CONTRIBUTING.md">Contribuir</a>
</p>

# ryk

Ejecuta agentes de programación con controles claros.

ryk es una capa de control local para los agentes que ya usan los ingenieros. Inicia Pi, Hermes, OpenCode, Codex o Claude mediante `ryk <agent>`. El agente conserva su flujo normal de terminal y herramientas, mientras ryk evalúa comandos, archivos, entorno y secretos, red, acciones MCP y otros efectos según la política.

Cada acción produce una decisión `allow`, `ask`, `deny` u `observe`. Las sesiones dejan un registro local que puedes consultar con `ryk dashboard` o `ryk replay`.

## Instalar

```sh
curl -fsSL https://rykanv.com/install | sh
```

Después de activar `ryk` en tu `PATH`, inicia un agente mediante `ryk <agent>`.

## Iniciar un agente

```sh
ryk pi
ryk hermes
ryk opencode
ryk codex
ryk claude
```

También hay rutas para OpenClaw y Grok:

```sh
ryk openclaw
ryk grok
```

Comprueba el estado local cuando lo necesites:

```sh
ryk doctor
```

Las integraciones principales son Pi, Hermes, OpenCode, Codex y Claude. El onboarding también detecta Cursor para el descubrimiento del host.

## Política

La política local cubre comandos, archivos, entorno, red y herramientas MCP. El modo define la respuesta:

| Modo | Comportamiento |
| --- | --- |
| `observe` | Registra decisiones sin bloquear acciones compatibles |
| `ask` | Pide confirmación para acciones riesgosas cuando el host es interactivo |
| `strict` | Deniega acciones desconocidas o riesgosas salvo que una regla las permita |
| `ci` | Ejecuta el comportamiento estricto sin preguntas |

Las denegaciones explícitas tienen prioridad. Los paquetes de seguridad clasifican comandos y efectos, pero no conceden permisos por encima de una denegación.

```sh
ryk policy check --preset ask
ryk policy packs
ryk test "git status"
ryk explain "rm -rf /"
```

Consulta la [guía completa de políticas](docs/policy.md).

## Paquetes de seguridad

El motor de shell incluye 86 paquetes integrados. Los paquetes base están activos por defecto. Añade los que necesite tu proyecto:

```sh
ryk packs
ryk packs show core.git
ryk packs enable containers.docker database.postgresql
ryk packs disable containers.docker
```

En un workspace Git, las selecciones del proyecto se guardan en `.orca.toml`. Usa `ryk packs --json` para automatización y diagnósticos.

## Arquitectura

Los alias de lanzamiento, los adaptadores de host, el evaluador de shell y el motor de políticas comparten una única ruta local de decisión.

<p align="center">
  <img src="docs/images/ryk-architecture.svg" alt="Arquitectura de ryk" width="100%">
</p>

1. El lanzamiento inicia una sesión con los valores predeterminados del agente.
2. Los adaptadores envían eventos de shell y herramientas al evaluador.
3. El evaluador combina reglas, paquetes y el modo activo.
4. La acción se permite, solicita confirmación, se observa o se deniega.
5. La evidencia alimenta el dashboard local y la reproducción de sesiones.

## Dashboard

```sh
ryk dashboard
```

Abre [http://127.0.0.1:7742](http://127.0.0.1:7742) en el navegador. Para automatización:

```sh
ryk dashboard --once
```

## Contribuir

ryk usa Zig 0.16.0. Ejecuta las comprobaciones enfocadas después de modificar el código:

```sh
./scripts/zig version
./scripts/compile-fast.sh check
./scripts/zig build
./scripts/zig build test-shell-engine
```

Lee [`CONTRIBUTING.md`](CONTRIBUTING.md) antes de abrir un pull request. Los problemas de seguridad deben seguir [`SECURITY.md`](SECURITY.md).

## Comunidad

- [Sitio web](https://rykanv.com/)
- [Discord](https://discord.gg/uZn9MDUYKx)
- [Issues](https://github.com/christopherkarani/ryk/issues)

Si ryk te resulta útil, [marca el repositorio con una estrella](https://github.com/christopherkarani/ryk). Ayuda a que otros ingenieros encuentren el proyecto.

## Licencia

Apache 2.0. Consulta [`LICENSE`](LICENSE).
