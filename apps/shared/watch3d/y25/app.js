import * as T from '../three.module.js';
const stage=document.querySelector('#stage');let renderer;try{renderer=new T.WebGLRenderer({antialias:true,alpha:true})}catch(e){document.querySelector('#error').style.display='block';throw e}renderer.setPixelRatio(Math.min(devicePixelRatio,2));renderer.setClearColor(0x000000,0);renderer.toneMapping=T.ACESFilmicToneMapping;renderer.toneMappingExposure=1.25;stage.appendChild(renderer.domElement);
const scene=new T.Scene(),camera=new T.PerspectiveCamera(34,1,.1,100);camera.position.set(0,0,12);const hemi=new T.HemisphereLight(0xffffff,0x887866,3);scene.add(hemi);for(const [x,y,z,power] of [[-4,7,6,100],[5,2,4,80],[-2,-4,-3,80]]){const l=new T.PointLight(0xffffff,power);l.position.set(x,y,z);scene.add(l)}
const watch=new T.Group();scene.add(watch);const metal=new T.MeshStandardMaterial({color:0xe6d3bd,metalness:.78,roughness:.22});const silver=new T.MeshStandardMaterial({color:0xcac9c5,metalness:.9,roughness:.2});const black=new T.MeshStandardMaterial({color:0x151416,metalness:.4,roughness:.18});
function mesh(geo,mat,parent=watch){const m=new T.Mesh(geo,mat);parent.add(m);return m}function disk(r,d,z,mat){const m=mesh(new T.CylinderGeometry(r,r,d,128),mat);m.rotation.x=Math.PI/2;m.position.z=z;return m}disk(1.33,.3,0,metal);disk(1.25,.07,.18,silver);disk(1.205,.07,.223,black);disk(1.14,.015,.265,black);
// Create the dial before centering the model; loading only updates its material.
const dialMaterial=new T.MeshBasicMaterial({color:0xffffff});
const dial=mesh(new T.CircleGeometry(1.115,128),dialMaterial);dial.position.z=.276;
new T.TextureLoader().load('./assets/peacock.png',tx=>{tx.colorSpace=T.SRGBColorSpace;dialMaterial.map=tx;dialMaterial.needsUpdate=true});
const glass=mesh(new T.SphereGeometry(1.19,96,32,0,Math.PI*2,0,Math.PI/2),new T.MeshPhongMaterial({color:0xffffff,transparent:true,opacity:.065,shininess:150,specular:0xffffff,depthWrite:false}));
glass.rotation.x=Math.PI/2;glass.scale.y=.035;glass.position.z=.286;
const ring=mesh(new T.TorusGeometry(1.27,.035,16,128),silver);ring.position.z=.216;
// Smooth porcelain-white silicone, with actual through-holes and rounded edges.
const silicone=new T.MeshStandardMaterial({color:0xfcfcfa,metalness:0,roughness:.64});
function roundedPath(path,x,y,w,h,r){
 path.moveTo(x+r,y);path.lineTo(x+w-r,y);path.quadraticCurveTo(x+w,y,x+w,y+r);
 path.lineTo(x+w,y+h-r);path.quadraticCurveTo(x+w,y+h,x+w-r,y+h);
 path.lineTo(x+r,y+h);path.quadraticCurveTo(x,y+h,x,y+h-r);
 path.lineTo(x,y+r);path.quadraticCurveTo(x,y,x+r,y);path.closePath();return path;
}
const strapRadius=2,strapStart=.75,strapEnd=Math.PI*2-.75;
const strapLength=(strapEnd-strapStart)*strapRadius;
const strapShape=roundedPath(new T.Shape(),-.52,-strapLength/2,1.04,strapLength,.16);
for(let i=0;i<9;i++){
 const angle=3.45+i*.2;
 const hole=roundedPath(new T.Path(),-.083,(angle-strapStart)*strapRadius-strapLength/2-.06,.166,.12,.045);
 strapShape.holes.push(hole);
}
let strapGeometry=new T.ExtrudeGeometry(strapShape,{depth:.075,bevelEnabled:true,bevelThickness:.012,bevelSize:.012,bevelSegments:3,steps:1,curveSegments:12});
// Subdivide every triangle along the strap length before bending.
const flat=strapGeometry.toNonIndexed ? (strapGeometry.index?strapGeometry.toNonIndexed():strapGeometry):strapGeometry;
const source=flat.attributes.position, refined=[];
function splitTriangle(a,b,c){
 const edges=[[a,b,c],[b,c,a],[c,a,b]];edges.sort((u,v)=>Math.abs(v[0][1]-v[1][1])-Math.abs(u[0][1]-u[1][1]));
 const [p,q,r]=edges[0];
 if(Math.abs(p[1]-q[1])>.09){const m=p.map((v,i)=>(v+q[i])/2);splitTriangle(p,m,r);splitTriangle(m,q,r);}
 else refined.push(...a,...b,...c);
}
for(let i=0;i<source.count;i+=3){const points=[0,1,2].map(j=>[source.getX(i+j),source.getY(i+j),source.getZ(i+j)]);splitTriangle(...points);}
strapGeometry=new T.BufferGeometry();strapGeometry.setAttribute('position',new T.Float32BufferAttribute(refined,3));
const strapPositions=strapGeometry.attributes.position;
for(let i=0;i<strapPositions.count;i++){
 const x=strapPositions.getX(i),length=strapPositions.getY(i),r=strapRadius+strapPositions.getZ(i)-.0375;
 const angle=strapStart+(length+strapLength/2)/strapRadius;
 strapPositions.setXYZ(i,x,Math.sin(angle)*r,Math.cos(angle)*r-1.55);
}
strapGeometry.computeVertexNormals();mesh(strapGeometry,silicone);
// Two silicone loops hold the strap tail, matching the real photographs.
for(const angle of [1.35,1.75]){
 const keeper=new T.Group();watch.add(keeper);keeper.position.set(0,Math.sin(angle)*2,Math.cos(angle)*2-1.55);keeper.rotation.x=Math.PI/2-angle;
 for(const y of [-.083,.083]){const bar=mesh(new T.BoxGeometry(1.14,.055,.20),silicone,keeper);bar.position.y=y;}
 for(const x of [-.55,.55]){const bar=mesh(new T.BoxGeometry(.065,.16,.20),silicone,keeper);bar.position.x=x;}
}
for(const y of [-1.23,1.23]){for(const x of [-.6,.6]){const lug=mesh(new T.BoxGeometry(.18,.53,.27),metal);lug.position.set(x,y,-.05);lug.rotation.x=y>0?-.18:.18}}
// Crown axis follows the radial direction of the circular case.
const crownAngle=.42,crownRadius=1.335;
const crownMount=new T.Group();watch.add(crownMount);
crownMount.position.set(Math.cos(crownAngle)*crownRadius,Math.sin(crownAngle)*crownRadius,0);
crownMount.rotation.z=crownAngle-Math.PI/2;
mesh(new T.CylinderGeometry(.14,.14,.09,64),silver,crownMount);
for(let i=0;i<48;i++){
 const a=i*Math.PI*2/48;
 const flute=mesh(new T.CylinderGeometry(.0045,.0045,.065,4),metal,crownMount);
 flute.position.set(Math.cos(a)*.14,0,Math.sin(a)*.14);
}
// Low profile curved button: most of its body is recessed into the case.
const side=mesh(new T.TorusGeometry(1.318,.028,12,40,.32),metal);side.rotation.z=-.63;
// Back follows the real reference: champagne base, silver ring and five sensors.
disk(1.14,.035,-.165,metal);
disk(.97,.018,-.19,silver);disk(.72,.022,-.205,metal);
for(const [x,y] of [[0,0],[.22,0],[-.22,0],[0,.22],[0,-.22]]){
 const sensor=disk(.072,.012,-.223,black);sensor.position.x=x;sensor.position.y=y;
 const lens=disk(.043,.008,-.233,new T.MeshStandardMaterial({color:0x34463d,metalness:.5,roughness:.2}));lens.position.x=x;lens.position.y=y;
}
for(const x of [-.09,.09]){const contact=disk(.052,.01,-.197,silver);contact.position.set(x,-.91,-.197)}
// Buckle and keeper on the back of the strap.
for(const y of [-.35,.35]){const b=mesh(new T.BoxGeometry(1.12,.075,.09),silver);b.position.set(0,y,-3.57)}for(const x of [-.53,.53]){const b=mesh(new T.BoxGeometry(.075,.7,.09),silver);b.position.set(x,0,-3.57)}const pin=mesh(new T.BoxGeometry(.045,.6,.06),silver);pin.position.set(0,0,-3.63);
// Center rotation in the middle of the strap loop, rather than the dial.
for (const part of watch.children) part.position.z += 1.55;
watch.position.z=-.6;
let auto=true,drag=false,lastX=0,lastY=0,ry=-.38,rx=.12,zoom=12,target=null;watch.rotation.set(rx,ry,-.07);document.querySelector('#auto').onclick=()=>{auto=!auto;document.querySelector('#auto').textContent=auto?'Dừng xoay':'Tự xoay';document.querySelector('#auto').classList.toggle('active',auto)};function view(y){auto=false;target=y;rx=.06;document.querySelector('#auto').textContent='Tự xoay';document.querySelector('#auto').classList.remove('active')}document.querySelector('#front').onclick=()=>view(0);document.querySelector('#back').onclick=()=>view(Math.PI);stage.onpointerdown=e=>{drag=true;target=null;lastX=e.clientX;lastY=e.clientY;stage.setPointerCapture(e.pointerId)};stage.onpointermove=e=>{if(!drag)return;ry+=(e.clientX-lastX)*.008;rx=Math.max(-1,Math.min(1,rx+(e.clientY-lastY)*.006));lastX=e.clientX;lastY=e.clientY};stage.onpointerup=()=>drag=false;stage.addEventListener('wheel',e=>{e.preventDefault();zoom=Math.max(7,Math.min(17,zoom+e.deltaY*.008))},{passive:false});function resize(){const w=stage.clientWidth,h=stage.clientHeight;renderer.setSize(w,h);camera.aspect=w/h;camera.updateProjectionMatrix();watch.position.set(w>700?1.35:0,w>700?0:-.45,-.6);zoom=window.WATCH_ZOOM||(w>700?12:14.5)}window.addEventListener('resize',resize);resize();let prev=0;function animate(t){const dt=Math.min((t-prev)/1000,.05);prev=t;if(auto&&!drag)ry+=dt*.3;if(target!==null){ry+=(target-ry)*.07;if(Math.abs(target-ry)<.002)target=null}watch.rotation.set(rx,ry,-.07);watch.position.y+=(Math.sin(t*.0008)*.025+ (stage.clientWidth>700?0:-.45)-watch.position.y)*.04;camera.position.z+=(zoom-camera.position.z)*.1;renderer.render(scene,camera);requestAnimationFrame(animate)}requestAnimationFrame(animate);
