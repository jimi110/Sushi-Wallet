# Wrapped · sesiones multijugador de Sushi Wallet

Wrapped añade a Sushi Wallet una segunda modalidad de sesión (**Solo** / **Wrapped**) con salas de hasta 4 jugadores, puntuación global compartida, clasificación, bonificaciones y reparto final, todo sincronizado con Supabase (Auth anónima + Realtime + RLS + RPC). Sigue siendo una app estática para GitHub Pages.

## Archivos

| Archivo | Qué es |
|---|---|
| `index.html` | App con los cambios (CSS al final del `<style>` y un segundo `<script>` al final del `<body>`). |
| `supabase/wrapped.sql` | Tablas, restricciones, triggers, RLS, funciones RPC, limpieza y publicación Realtime. |
| `supabase/wrapped_tests.sql` | Pruebas SQL de la función de reparto (para ejecutar en el editor SQL). |
| `tests/wrapped-core.test.js` | Pruebas Node del reparto, empates, códigos y estados (`node --test tests/wrapped-core.test.js`). |

## Configuración (una sola vez)

1. En Supabase: **Authentication → Providers → Anonymous Sign-Ins → activar**.
2. **SQL Editor**: pega y ejecuta `supabase/wrapped.sql`, y después `supabase/wrapped_tests.sql` (debe terminar con `NOTICE: ... todos los casos OK`).
3. Comprueba en **Database → Replication/Publications** que `supabase_realtime` incluye las tablas `wr_*` (el script las añade).
4. En `index.html`, busca `WR_CONFIG` y rellena `url` (Project URL) y `anonKey` (clave `anon`/`publishable`). **Nunca** pongas la `service_role`. La app se niega a usar una clave que contenga ese texto.
5. Opcional: programa la limpieza con `pg_cron` (línea comentada al final de la sección «Limpieza» del SQL). Si no, se ejecuta sola cada vez que alguien crea una sala.
6. Si tu `sw.js` guarda `index.html` en caché con un nombre de versión, súbela para que los usuarios reciban la nueva versión. (No he podido ver `sw.js`.)

## Cómo funciona

- **Identidad:** `signInAnonymously()`; el `user_id` de Supabase es la identidad de seguridad. El apodo es solo visual. La sesión se guarda en el navegador (`sw-wrapped-auth`) y permite volver a la sala tras recargar.
- **Escrituras:** los clientes no pueden insertar/actualizar/borrar en ninguna tabla (solo `select` con RLS por pertenencia). Todo pasa por RPC `SECURITY DEFINER` que usan `auth.uid()`: `wr_create_room`, `wr_join_room`, `wr_leave_room`, `wr_kick`, `wr_start_room`, `wr_set_item`, `wr_finish_participation`, `wr_claim_reward`, `wr_roulette`, `wr_roulette_answer`. `wr_try_finalize` y `wr_cleanup` no son ejecutables por clientes.
- **Estados de sala:** `waiting → active → finalizing → completed`, y `expired`. Un trigger impide transiciones inválidas (una sala completada no se finaliza otra vez). `finalizing` es transitorio dentro de la misma transacción, por lo que los clientes normalmente no lo ven.
- **Plazas:** `wr_join_room` bloquea la fila de la sala (`FOR UPDATE`) antes de contar, y un trigger repite la comprobación; la PK `(room_id,user_id)` impide duplicar identidad. Un quinto jugador recibe `room_full` aunque entren a la vez.
- **Aportaciones idempotentes:** `wr_set_item` guarda la **cantidad absoluta** por plato con un `seq` creciente; un reintento de red o un paquete tardío no suma dos veces. La UI no muestra un plato como registrado hasta que el servidor responde.
- **Sincronización:** un canal Realtime por sala (`postgres_changes` filtrado por sala) para sala, jugadores, aportaciones, resultados y ruleta. Al (re)conectar, al volver a la pestaña y al recuperar la red se recarga el estado completo desde la base de datos; los eventos no son la única fuente. No hay sondeo por intervalos. Los canales se eliminan al salir o reconectar.
- **Anfitrión desconectado:** la sala no depende de su navegador; los jugadores siguen y el último en terminar dispara el cierre en el servidor.
- **Limpieza:** salas en espera > 2 h → caducadas; salas activas sin actividad > 24 h → se cierran con lo confirmado; caducadas > 7 días → se borran. Las completadas nunca se borran.

## Reparto (fórmula exacta)

Trabajando en céntimos de punto (2 decimales, la precisión de la app):

```
global  = Σ aportaciones de los jugadores que terminaron (los expulsados no cuentan)
base_i  = floor(global / n) + (1 céntimo si i está entre los primeros (global mod n) del orden)
          orden: aportación desc, entrada a la sala asc, id asc  → la bolsa se reparte entera
puesto  = ranking de competición por aportación individual (empates comparten puesto: 1,1,3,4)
bonus_i = round_half_up(base_i × pct(puesto_i) / 100)     pct = 15 / 10 / 5 / 0 %
total_i = base_i + bonus_i                                (los bonus son puntos adicionales)
```

Los porcentajes están en **un solo sitio**: `wr_bonus_pct()` en `wrapped.sql` (el servidor calcula y guarda; el cliente solo muestra los valores guardados). El espejo `WR_BONUS` de `index.html` solo alimenta las pruebas. Con un único jugador no hay bonificación (`WR_MIN_FOR_BONUS = 2`, también en `wr_bonus_pct`); si prefieres +15 % también en ese caso, cambia `p_players < 2` a `p_players < 1`.

## Recompensas sin duplicados

1. El cierre ocurre una sola vez: bloqueo de la sala, comprobación de estado `active`, PK única en `wr_results(room_id)` y `wr_result_players(room_id,user_id)`, y trigger de transiciones.
2. Cada jugador solo puede reclamar su propia fila (`wr_claim_reward` usa `auth.uid()`).
3. El saldo vive en `localStorage` (`st.adj`). La recompensa se añade como un movimiento con **id único `wr:<id de sala>`**; si ya existe ese id no se vuelve a sumar. El orden es: comprobar comprobante local → añadir movimiento → marcar `applied_at` en el servidor. Si falla el último paso se reintenta sin volver a sumar.
4. Los puntos de la partida **no** tocan el saldo durante la sesión. Solo, logros, canjes, transferencias e historial no se modifican (los movimientos Wrapped llevan `k:'wr'`, así que no cuentan como «puntos recibidos» para logros).

## Cambios en el código existente (mínimos)

- Se envuelven `paneSess`, `changeQty`, `totals`, `sum`, `regList` y `A.regedit`; **solo cambian de comportamiento con una sala Wrapped abierta**. En Solo llaman directamente a las originales.
- `A.startgo` (botón «Iniciar sesión» del Inicio): ahora lleva a la pestaña Sesión para elegir Solo/Wrapped en vez de crear una sesión Solo al instante. Dentro de Solo, «Comenzar sesión» funciona igual que antes.
- En Wrapped, `st.sess` actúa como espejo en memoria de tus platos confirmados (nunca se guarda con `save('sess')`) para reutilizar el panel «Añadir sushi», la carta, el buscador y la lista de registrados.
- Invitación por QR/enlace: `…/index.html#wr=CODIGO` abre «Unirse» con el código rellenado; reutiliza el generador QR existente.

## Pruebas

Ejecutadas aquí:
- `node --test tests/wrapped-core.test.js`: **18/18 correctas** (reparto con 1, 2, 3 y 4 jugadores, empates en 1.º/2.º/4 jugadores, restos, 1000 casos aleatorios con invariantes, códigos sin O/0/I/1, transiciones de estado, quinto jugador).
- Prueba de humo en Chromium sin cabeza **con un Supabase simulado en memoria** (no es Supabase real): selector Solo/Wrapped, crear sala, lobby, entrada de un segundo jugador, inicio, registro con el panel original, puntuación global, ruleta, terminar, resultados, crédito único al saldo, vuelta al menú, Solo intacto. Sin errores de JavaScript.

**No ejecutadas (necesitan tu proyecto Supabase):** `wrapped.sql` y `wrapped_tests.sql` (sin base de datos disponible aquí), y por tanto las pruebas reales de: varios navegadores/dispositivos, quinto jugador concurrente, aislamiento entre salas (RLS), aportaciones simultáneas, recarga/desconexión, cierre simultáneo y reparto único en servidor, y Realtime. El SQL está escrito con cuidado pero puede necesitar algún ajuste al ejecutarlo por primera vez. Lista de comprobación manual: 2–3 pestañas (una en incógnito), crea sala → une → quinto rechazado → empieza → registra → recarga → apaga la red 20 s → termina todos → comprueba que cada saldo recibe solo lo suyo.

## Limitaciones conocidas

- **Puntos por plato declarados por el cliente.** La carta vive en el navegador, así que el servidor no puede saber cuánto vale cada plato. Valida rangos (cantidad 0–99, ≤100 pts/unidad, ≤300 platos), pero un cliente manipulado podría declarar puntos falsos. El servidor sí calcula siempre totales, clasificación y reparto. Solución completa: guardar la carta en Supabase (fuera del alcance pedido).
- Los jugadores deben compartir la misma carta (`carta.txt`). Un plato de la ruleta que no exista en tu carta cuenta y aparece en la lista, pero no se puede editar.
- Los puntos de un jugador expulsado dejan de contar; con un único jugador restante no hay bonificación.
- El saldo sigue siendo local (por dispositivo): la recompensa se acredita en el dispositivo que abre los resultados. Si borras los datos tras reclamar, el servidor la marca como aplicada y no se vuelve a acreditar.
- `supabase-js` se carga desde jsDelivr/unpkg fijado a `2.45.4` (no verificado desde aquí); si lo prefieres, descárgalo y sírvelo desde tu repositorio.
- No hay límite de intentos al adivinar códigos de sala (32⁸ combinaciones); conocer un código solo permite *unirse* a una sala en espera, nunca leer ni modificar datos ajenos.
- Si tu `sw.js` cachea agresivamente, hace falta subir su versión.
