// Pruebas del núcleo de Wrapped (reparto, empates, estados de sala). Ejecutar:  node --test tests/
// Extrae el bloque WR-CORE de index.html para probar exactamente el código que se publica.
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path');
const html=fs.readFileSync(path.join(__dirname,'..','index.html'),'utf8');
const core=html.split('/*WR-CORE-START*/')[1].split('/*WR-CORE-END*/')[0];
const W=new Function(core+';return{wrDistribute,wrBonusPct,wrCodeRe,wrNormCode,wrCanTransition,wrCanStart,wrCanJoin,wrErrText,WR_BONUS}')();
const P=(id,c,j)=>({id,cents:c,joined:j||'2026-01-01T00:00:0'+id.charCodeAt(0)%10});
const by=(r,id)=>r.rows.find(x=>x.id===id);

test('ejemplo del enunciado: 100 puntos entre 4 → base 25; bonus 3,75 / 2,5 / 1,25 / 0',()=>{
  const r=W.wrDistribute([P('a',4000),P('b',3000),P('c',2000),P('d',1000)]);
  assert.equal(r.global,10000);
  assert.deepEqual(r.rows.map(x=>[x.place,x.base,x.bonus,x.total]),[[1,2500,375,2875],[2,2500,250,2750],[3,2500,125,2625],[4,2500,0,2500]]);
  assert.equal(r.credited,10750);                                   // puede superar la global: las bonificaciones son adicionales
});
test('ejemplo 24+18+15+13 = 70 puntos',()=>{
  const r=W.wrDistribute([P('a',2400),P('b',1800),P('c',1500),P('d',1300)]);
  assert.equal(r.global,7000);assert.equal(r.rows[0].base,1750);
  assert.equal(by(r,'a').bonus,263);                                // 17,50 × 15 % = 2,625 → 2,63 (mitad hacia arriba)
  assert.equal(by(r,'b').bonus,175);assert.equal(by(r,'c').bonus,88);assert.equal(by(r,'d').bonus,0);
});
test('1 jugador: sin rivales no hay bonificación, recibe todo su aporte',()=>{
  const r=W.wrDistribute([P('a',1234)]);
  assert.deepEqual(r.rows[0],{id:'a',place:1,contrib:1234,base:1234,pct:0,bonus:0,total:1234});
});
test('2 jugadores: solo existen 1.º (+15 %) y 2.º (+10 %)',()=>{
  const r=W.wrDistribute([P('a',1000),P('b',500)]);
  assert.deepEqual(r.rows.map(x=>[x.place,x.pct,x.base,x.bonus]),[[1,15,750,113],[2,10,750,75]]);   // 7,50×15 % = 1,125 → 1,13
});
test('3 jugadores: puestos 1.º, 2.º, 3.º (+15/+10/+5)',()=>{
  const r=W.wrDistribute([P('a',900),P('b',600),P('c',300)]);
  assert.deepEqual(r.rows.map(x=>x.pct),[15,10,5]);assert.equal(r.global,1800);assert.ok(r.rows.every(x=>x.base===600));
});
test('el resto de la división se reparte sin perder céntimos, de forma determinista',()=>{
  // 1001 céntimos entre 3 → 333 + resto 2: los dos primeros del orden reciben +1
  const r=W.wrDistribute([P('a',500),P('b',300),P('c',201)]);
  assert.equal(r.global,1001);
  assert.equal(r.rows.reduce((s,x)=>s+x.base,0),1001);              // la bolsa se reparte entera
  assert.deepEqual(r.rows.map(x=>x.base),[334,334,333]);
  const r2=W.wrDistribute([P('c',201),P('b',300),P('a',500)]);      // independiente del orden de entrada
  assert.deepEqual(r2.rows.map(x=>[x.id,x.base]),r.rows.map(x=>[x.id,x.base]));
});
test('empate por el 1.º puesto: ambos +15 %, el siguiente es 3.º (+5 %)',()=>{
  const r=W.wrDistribute([P('a',1000),P('b',1000),P('c',500),P('d',100)]);
  assert.deepEqual(r.rows.map(x=>x.place),[1,1,3,4]);
  assert.deepEqual(r.rows.map(x=>x.pct),[15,15,5,0]);
});
test('empate a cuatro: todos 1.º con +15 %',()=>{
  const r=W.wrDistribute([P('a',500),P('b',500),P('c',500),P('d',500)]);
  assert.ok(r.rows.every(x=>x.place===1&&x.pct===15&&x.base===500&&x.bonus===75));
});
test('empate por el 2.º: ambos +10 %, el último es 4.º (+0 %)',()=>{
  const r=W.wrDistribute([P('a',900),P('b',500),P('c',500),P('d',100)]);
  assert.deepEqual(r.rows.map(x=>[x.place,x.pct]),[[1,15],[2,10],[2,10],[4,0]]);
});
test('todos a cero: reparto 0 sin errores',()=>{
  const r=W.wrDistribute([P('a',0),P('b',0)]);assert.equal(r.global,0);assert.equal(r.credited,0);
});
test('sin jugadores: resultado vacío (no se inventan posiciones)',()=>{assert.deepEqual(W.wrDistribute([]).rows,[])});
test('invariante: Σ base = global y Σ total = global + Σ bonus (1000 casos aleatorios)',()=>{
  let seed=7;const rnd=()=>(seed=(seed*1103515245+12345)&0x7fffffff)/0x7fffffff;
  for(let t=0;t<1000;t++){const n=1+Math.floor(rnd()*4),ps=Array.from({length:n},(_,i)=>P('u'+i,Math.floor(rnd()*5)*Math.floor(rnd()*3000),'2026-01-01T00:00:0'+i));
    const r=W.wrDistribute(ps);assert.equal(r.rows.reduce((s,x)=>s+x.base,0),r.global);
    assert.equal(r.credited,r.global+r.rows.reduce((s,x)=>s+x.bonus,0));assert.equal(r.rows.length,n);
    assert.ok(r.rows.every(x=>x.pct===W.wrBonusPct(x.place,n)&&x.place>=1&&x.place<=n))}
});
test('porcentajes definidos en un único lugar',()=>{assert.deepEqual(W.WR_BONUS,[15,10,5,0]);assert.equal(html.split('const WR_BONUS=').length,2)});

test('código de sala: 8 caracteres sin O/0/I/1',()=>{
  assert.ok(W.wrCodeRe.test('K7M2QX9P'));
  for(const bad of ['K7M2QX9O','K7M2QX90','K7M2QX9I','K7M2QX91','K7M2QX9','K7M2QX9PP','k7m2qx9p'])assert.ok(!W.wrCodeRe.test(bad),bad);
  assert.equal(W.wrNormCode(' k7m2-qx9p '),'K7M2QX9P');
});
test('estados de sala: transiciones válidas y sala completada inmodificable',()=>{
  assert.ok(W.wrCanTransition('waiting','active'));assert.ok(W.wrCanTransition('active','finalizing'));assert.ok(W.wrCanTransition('finalizing','completed'));
  assert.ok(!W.wrCanTransition('completed','active'));assert.ok(!W.wrCanTransition('completed','finalizing'));   // no se finaliza dos veces
  assert.ok(!W.wrCanTransition('waiting','completed'));assert.ok(!W.wrCanTransition('expired','waiting'));
});
test('iniciar: solo en espera y con 2–4 jugadores',()=>{
  assert.ok(!W.wrCanStart('waiting',1));assert.ok(W.wrCanStart('waiting',2));assert.ok(W.wrCanStart('waiting',4));
  assert.ok(!W.wrCanStart('waiting',5));assert.ok(!W.wrCanStart('active',3));
});
test('unirse: quinto jugador rechazado; sala empezada/cerrada rechazada',()=>{
  assert.equal(W.wrCanJoin('waiting',3),'ok');assert.equal(W.wrCanJoin('waiting',4),'room_full');
  assert.equal(W.wrCanJoin('active',2),'room_started');assert.equal(W.wrCanJoin('completed',2),'room_closed');assert.equal(W.wrCanJoin('expired',0),'room_closed');
});
test('mensajes de error comprensibles para cada caso exigido',()=>{
  for(const c of ['room_not_found','room_full','room_started','room_closed','already_in_room','timeout','network','kicked'])assert.ok(W.wrErrText(c).length>10,c);
});
