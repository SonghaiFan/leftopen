import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import https from 'node:https';
import http2 from 'node:http2';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { gateRoutes } from '../../.build/portless-runtime/lease-gate.mjs';
import { syncRoutes, atomicJSON } from '../../.build/portless-runtime/routes.mjs';
import { RouteStore } from '../../.build/portless-runtime/package/dist/index.js';
const runtime = path.resolve('.build/portless-runtime');
const cli = path.join(runtime, 'package/dist/cli.js');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
function directory(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'leftopen-service-test-'));
  t.after(() => fs.rmSync(dir, { force: true, recursive: true }));
  return dir;
}
async function eventually(check) {
  let last;
  for (let i = 0; i < 100; i++) {
    try { const value = await check(); if (value) return value; } catch (error) { last = error; }
    await delay(100);
  }
  throw last ?? new Error('Timed out');
}
function json(file, value) { fs.writeFileSync(file, JSON.stringify(value)); }

test('observation leases expire and fail closed, while live upstream sessions retain their ownership', t => {
  const dir = directory(t);
  const routes = [{hostname:'observed.localhost',port:3000,pid:42}, {hostname:'started.localhost',port:4000,pid:43}];
  assert.deepEqual(gateRoutes(routes, dir, 100, () => true), []);
  atomicJSON(path.join(dir, 'leftopen-managed.json'), ['observed.localhost']);
  atomicJSON(path.join(dir, 'leftopen-leases.json'), {expiresAt:200,routes:[{...routes[0],ownerPid:42,pid:44}]});
  assert.equal(gateRoutes(routes, dir, 100, () => true).length, 2);
  assert.deepEqual(gateRoutes(routes, dir, 201, () => true), [routes[1]]);
  assert.deepEqual(gateRoutes(routes, dir, 100, pid => pid !== 44), [routes[1]]);
  assert.deepEqual(gateRoutes(routes, dir, 100, pid => pid !== 43), [routes[0]]);
  assert.deepEqual(gateRoutes([{...routes[0],port:5000}], dir, 100, () => true), []);
});

test('route updates preserve wrapper ownership and refuse collisions without signalling it', t => {
  const dir = directory(t);
  const store = new RouteStore(dir);
  const owner = spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)'], {stdio:'ignore'});
  t.after(() => owner.kill());
  store.addRoute('app.localhost', 3000, owner.pid);
  const lease = syncRoutes(dir, [{hostname:'app.localhost',port:3000,pid:process.pid}]);
  assert.equal(lease[0].ownerPid, owner.pid);
  assert.equal(store.loadRoutes()[0].pid, owner.pid);
  assert.equal(gateRoutes(store.loadRoutes(), dir).length, 1);
  // A separate owner cannot be overwritten by a native alias.
  store.addRoute('other.localhost', 4000, owner.pid);
  assert.throws(() => syncRoutes(dir, [{hostname:'other.localhost',port:5000,pid:process.pid}]));
  assert.equal(owner.exitCode, null);
  assert.ok(gateRoutes(store.loadRoutes(), dir).find(r => r.hostname === 'other.localhost'));
  assert.equal(store.loadRoutes().find(r => r.hostname === 'other.localhost').port, 4000);
  syncRoutes(dir, []);
  assert.equal(store.loadRoutes().find(r => r.hostname === 'app.localhost'), undefined);
  assert.ok(store.loadRoutes().find(r => r.hostname === 'other.localhost'));
});

test('project inspection uses upstream config and worktree naming without executing scripts', t => {
  const dir = directory(t);
  json(path.join(dir, 'package.json'), {name:'example',scripts:{dev:'node server.mjs'}});
  json(path.join(dir, 'portless.json'), {name:'configured-app',script:'dev'});
  const info = cwd => {
    const result = spawnSync(process.execPath, [cli,'--leftopen-project-info'], {cwd, encoding:'utf8',env:{PATH:'/usr/bin:/bin',HOME:os.homedir()}});
    assert.equal(result.status,0,result.stderr);
    return JSON.parse(result.stdout);
  };
  assert.equal(info(dir).baseName, 'configured-app');
  assert.equal(info(dir).canStart, true);
  assert.equal(fs.existsSync(path.join(dir, 'server.mjs')), false);
  const git = args => { const r=spawnSync('/usr/bin/git',args,{cwd:dir,encoding:'utf8'}); assert.equal(r.status,0,r.stderr); };
  git(['init','-q']); git(['-c','user.name=Test','-c','user.email=test@example.invalid','commit','--allow-empty','-qm','test']);
  const worktree = path.join(dir,'branch'); git(['worktree','add','-qb','feature/demo',worktree]);
  json(path.join(worktree,'package.json'),{name:'example',scripts:{dev:'node server.mjs'}});
  json(path.join(worktree,'portless.json'),{name:'configured-app'});
  const branch = info(worktree);
  assert.ok(branch.worktreePrefix);
  assert.equal(branch.name, `${branch.worktreePrefix}.configured-app`);
  json(path.join(dir,'package.json'),{name:'example',scripts:{dev:'portless run'}});
  assert.equal(info(dir).canStart,false);
});

test('real pinned HTTPS proxy validates certificates, serves HTTP/2, and expires native routes', async t => {
  const dir=directory(t);
  const backend=http.createServer((req,res)=>res.end('secure-backend'));
  backend.listen(0,'127.0.0.1'); await once(backend,'listening');
  t.after(()=>backend.close());
  // Use an unprivileged ephemeral proxy port: no system hosts changes or CA trust installation.
  const reservation=http.createServer(); reservation.listen(0,'127.0.0.1'); await once(reservation,'listening');
  const port=reservation.address().port; await new Promise(resolve=>reservation.close(resolve));
  syncRoutes(dir,[{hostname:'secure.localhost',port:backend.address().port,pid:process.pid}]);
  const proxy=spawn(process.execPath,[cli,'proxy','start','--https','--skip-trust','--foreground','--port',String(port)],
    {env:{PATH:'/usr/bin:/bin:/usr/sbin:/sbin',HOME:os.homedir(),PORTLESS_STATE_DIR:dir,PORTLESS_SYNC_HOSTS:'0',PORTLESS_LAN:'0'},stdio:'ignore'});
  t.after(async()=>{ if(proxy.exitCode===null){ const exited=once(proxy,'exit'); proxy.kill(); await exited; } });
  await eventually(()=>fs.existsSync(path.join(dir,'proxy.pid')) && fs.existsSync(path.join(dir,'ca.pem')));
  const ca=fs.readFileSync(path.join(dir,'ca.pem'));
  const get=()=>new Promise((resolve,reject)=>{
    const req=https.get({hostname:'127.0.0.1',servername:'secure.localhost',port,ca,headers:{Host:`secure.localhost:${port}`},timeout:2000},res=>{
      let body='';res.on('data',part=>body+=part);res.on('end',()=>resolve({status:res.statusCode,body}));
    });req.on('error',reject);req.on('timeout',()=>req.destroy(new Error('Timeout')));
  });
  assert.equal((await eventually(async()=>{const r=await get();return r.status===200?r:null;})).body,'secure-backend');
  const session=http2.connect(`https://127.0.0.1:${port}`,{servername:'secure.localhost',ca});
  const req=session.request({':path':'/',':authority':`secure.localhost:${port}`});
  let body='';req.on('data',chunk=>body+=chunk);await once(req,'end'); session.close();
  assert.equal(body,'secure-backend');
  atomicJSON(path.join(dir,'leftopen-leases.json'),{expiresAt:0,routes:[]});
  assert.equal((await get()).status,404);
});

test('upstream saved-project launch allocates ports and discovers workspace services', async t => {
  const dir=directory(t);
  const project=path.join(dir,'project');fs.mkdirSync(project);
  const state=path.join(dir,'state');syncRoutes(state,[]);
  const blocker=http.createServer();blocker.listen(4000,'127.0.0.1');await once(blocker,'listening');
  t.after(()=>blocker.close());
  const server="import http from 'node:http';http.createServer((req,res)=>res.end(String(process.env.PORT))).listen(Number(process.env.PORT),'127.0.0.1');";
  json(path.join(project,'package.json'),{name:'workspace',private:true,workspaces:['apps/*']});
  for (const name of ['web','api']) {
    const folder=path.join(project,'apps',name);fs.mkdirSync(folder,{recursive:true});
    json(path.join(folder,'package.json'),{name,scripts:{dev:'node server.mjs'}});
    fs.writeFileSync(path.join(folder,'server.mjs'),server);
  }
  const proxyPortServer=http.createServer();proxyPortServer.listen(0,'127.0.0.1');await once(proxyPortServer,'listening');
  const port=proxyPortServer.address().port;await new Promise(resolve=>proxyPortServer.close(resolve));
  const env={PATH:process.env.PATH,HOME:os.homedir(),PORTLESS_STATE_DIR:state,PORTLESS_SYNC_HOSTS:'0',PORTLESS_LAN:'0',PORTLESS_PORT:String(port),PORTLESS_HTTPS:'0',CI:'1'};
  const proxy=spawn(process.execPath,[cli,'proxy','start','--no-tls','--skip-trust','--foreground','--port',String(port)],{env,stdio:'ignore'});
  t.after(async()=>{if(proxy.exitCode===null){const exited=once(proxy,'exit');proxy.kill();await exited;}});
  await eventually(()=>fs.existsSync(path.join(state,'proxy.pid')));
  const inspected=spawnSync(process.execPath,[cli,'--leftopen-project-info'],{cwd:project,env,encoding:'utf8'});
  const info=JSON.parse(inspected.stdout);assert.equal(info.workspace,true);assert.equal(info.canStart,true);
  const job=spawn(process.execPath,[cli,'--script','dev'],{cwd:project,env,stdio:'ignore'});
  t.after(async()=>{if(job.exitCode===null){const exited=once(job,'exit');job.kill();await exited;}});
  const store=new RouteStore(state);
  const routes=await eventually(()=>{const r=store.loadRoutes();return r.filter(row=>row.pid===job.pid).length===2?r:null;});
  assert.equal(new Set(routes.map(r=>r.port)).size,2);
  assert.ok(routes.every(r=>r.port!==4000));
  const get=route=>new Promise((resolve,reject)=>{const req=http.get({hostname:'127.0.0.1',port,headers:{Host:`${route.hostname}:${port}`}},res=>{let body='';res.on('data',chunk=>body+=chunk);res.on('end',()=>resolve({status:res.statusCode,body}));});req.on('error',reject);});
  for(const route of routes) {const r=await eventually(async()=>{const result=await get(route);return result.status===200?result:null;});assert.equal(r.body,String(route.port));}
  const exited=once(job,'exit');job.kill();await exited;
  assert.equal(store.loadRoutes().length,0);
});
