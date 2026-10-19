import * as T from '../three.module.js';
const stage=document.querySelector('#stage');let renderer;try{renderer=new T.WebGLRenderer({antialias:true,alpha:true})}catch(e){document.querySelector('#error').style.display='block';throw e}renderer.setPixelRatio(Math.min(devicePixelRatio,2));renderer.setClearColor(0x000000,0);renderer.toneMapping=T.ACESFilmicToneMapping;renderer.toneMappingExposure=1.25;stage.appendChild(renderer.domElement);
const scene=new T.Scene(),camera=new T.PerspectiveCamera(34,1,.1,100);camera.position.set(0,0,12);const hemi=new T.HemisphereLight(0xffffff,0x887866,3);scene.add(hemi);for(const [x,y,z,power] of [[-4,7,6,100],[5,2,4,80],[-2,-4,-3,80]]){const l=new T.PointLight(0xffffff,power);l.position.set(x,y,z);scene.add(l)}
// Studio reflection panels reveal the dark metal edges and buckle details.
const studio=new T.Scene();studio.background=new T.Color(0x999999);
for(const [x,y,z,w,h] of [[-4,2,3,3,7],[4,1,2,2,6],[0,5,-2,5,2]]){
 const panel=new T.Mesh(new T.PlaneGeometry(w,h),new T.MeshBasicMaterial({color:0xffffff}));panel.position.set(x,y,z);panel.lookAt(0,0,0);studio.add(panel);
}
const pmrem=new T.PMREMGenerator(renderer);const studioMap=pmrem.fromScene(studio,.05);scene.environment=studioMap.texture;pmrem.dispose();
const watch=new T.Group();scene.add(watch);const metal=new T.MeshStandardMaterial({color:0x242628,metalness:.8,roughness:.3});const silver=new T.MeshStandardMaterial({color:0x414548,metalness:.85,roughness:.25});const black=new T.MeshStandardMaterial({color:0x151416,metalness:.4,roughness:.18});
function mesh(geo,mat,parent=watch){const m=new T.Mesh(geo,mat);parent.add(m);return m}function disk(r,d,z,mat){const m=mesh(new T.CylinderGeometry(r,r,d,128),mat);m.rotation.x=Math.PI/2;m.position.z=z;return m}disk(1.33,.3,0,metal);disk(1.25,.07,.18,silver);disk(1.205,.07,.223,black);disk(1.14,.015,.265,black);
// Create the dial before centering the model; loading only updates its material.
const dialMaterial=new T.MeshBasicMaterial({color:0xffffff});
const dial=mesh(new T.CircleGeometry(1.115,128),dialMaterial);dial.position.z=.276;
new T.TextureLoader().load('./assets/peacock.png',tx=>{tx.colorSpace=T.SRGBColorSpace;dialMaterial.map=tx;dialMaterial.needsUpdate=true});
const glass=mesh(new T.SphereGeometry(1.19,96,32,0,Math.PI*2,0,Math.PI/2),new T.MeshPhongMaterial({color:0xffffff,transparent:true,opacity:.065,shininess:150,specular:0xffffff,depthWrite:false}));
glass.rotation.x=Math.PI/2;glass.scale.y=.035;glass.position.z=.286;
const ring=mesh(new T.TorusGeometry(1.27,.035,16,128),silver);ring.position.z=.216;
// Smooth charcoal-black silicone, with actual through-holes and rounded edges.
const silicone=new T.MeshStandardMaterial({color:0x242625,metalness:0,roughness:.83});
function roundedPath(path,x,y,w,h,r){
 path.moveTo(x+r,y);path.lineTo(x+w-r,y);path.quadraticCurveTo(x+w,y,x+w,y+r);
 path.lineTo(x+w,y+h-r);path.quadraticCurveTo(x+w,y+h,x+w-r,y+h);
 path.lineTo(x+r,y+h);path.quadraticCurveTo(x,y+h,x,y+h-r);
 path.lineTo(x,y+r);path.quadraticCurveTo(x,y,x+r,y);path.closePath();return path;
}
const strapRadius=2;
function siliconeSegment(strapStart,strapEnd){
 const strapLength=(strapEnd-strapStart)*strapRadius;
 const strapShape=roundedPath(new T.Shape(),-.52,-strapLength/2,1.04,strapLength,.12);
 for(let angle=strapStart+.26;angle<strapEnd-.15;angle+=.22){
  for(const [x,r] of [[-.255,.043],[0,.066],[.255,.043]]){
   const hole=new T.Path();hole.absarc(x,(angle-strapStart)*strapRadius-strapLength/2,r,0,Math.PI*2,true);strapShape.holes.push(hole);
  }
 }
 let geometry=new T.ExtrudeGeometry(strapShape,{depth:.085,bevelEnabled:true,bevelThickness:.01,bevelSize:.01,bevelSegments:3,steps:1,curveSegments:10});
 const source=geometry.attributes.position,refined=[];
 function splitTriangle(a,b,c){
  const edges=[[a,b,c],[b,c,a],[c,a,b]];edges.sort((u,v)=>Math.abs(v[0][1]-v[1][1])-Math.abs(u[0][1]-u[1][1]));
  const [p,q,r]=edges[0];
  if(Math.abs(p[1]-q[1])>.09){const m=p.map((v,i)=>(v+q[i])/2);splitTriangle(p,m,r);splitTriangle(m,q,r);}
  else refined.push(...a,...b,...c);
 }
 for(let i=0;i<source.count;i+=3)splitTriangle(...[0,1,2].map(j=>[source.getX(i+j),source.getY(i+j),source.getZ(i+j)]));
 geometry.dispose();geometry=new T.BufferGeometry();geometry.setAttribute('position',new T.Float32BufferAttribute(refined,3));
 const positions=geometry.attributes.position;
 for(let i=0;i<positions.count;i++){
  const x=positions.getX(i),length=positions.getY(i),radius=strapRadius+positions.getZ(i)-.0425;
  const angle=strapStart+(length+strapLength/2)/strapRadius;
  positions.setXYZ(i,x,Math.sin(angle)*radius,Math.cos(angle)*radius-1.55);
 }
 geometry.computeVertexNormals();mesh(geometry,silicone);
}
// Separate strap ends leave the buckle opening clear.
siliconeSegment(.75,Math.PI-.17);siliconeSegment(Math.PI+.17,Math.PI*2-.75);
// Two silicone loops hold the strap tail, matching the real photographs.
for(const angle of [1.35,1.75]){
 const keeper=new T.Group();watch.add(keeper);keeper.position.set(0,Math.sin(angle)*2,Math.cos(angle)*2-1.55);keeper.rotation.x=Math.PI/2-angle;
 for(const y of [-.083,.083]){const bar=mesh(new T.BoxGeometry(1.14,.055,.20),silicone,keeper);bar.position.y=y;}
 for(const x of [-.55,.55]){const bar=mesh(new T.BoxGeometry(.065,.16,.20),silicone,keeper);bar.position.x=x;}
}
// Tapered lugs slope down toward the wrist instead of rectangular blocks.
for(const sign of [-1,1])for(const x of [-.70,.53]){
 const profile=new T.Shape();profile.moveTo(-.075,1.03);profile.lineTo(.17,1.03);profile.lineTo(.30,1.46);profile.lineTo(.155,1.46);profile.closePath();
 const geo=new T.ExtrudeGeometry(profile,{depth:.17,bevelEnabled:true,bevelThickness:.025,bevelSize:.025,bevelSegments:3,steps:1});
 const lug=mesh(geo,metal);lug.rotation.y=Math.PI/2;lug.scale.y=sign;lug.position.x=x;
}
// Two identical elongated buttons follow the curved case and sit nearly flush.
for(const angle of [.43,-.43]){
 const radius=1.32,halfArc=.13,buttonRadius=.038;
 const button=mesh(new T.TorusGeometry(radius,buttonRadius,12,32,halfArc*2),metal);button.rotation.z=angle-halfArc;
 for(const end of [angle-halfArc,angle+halfArc]){
  const roundedEnd=mesh(new T.SphereGeometry(buttonRadius,16,12),metal);
  roundedEnd.position.set(Math.cos(end)*radius,Math.sin(end)*radius,0);
 }
}
// Back follows the real reference: champagne base, silver ring and five sensors.
disk(1.14,.035,-.165,metal);
disk(.97,.018,-.19,silver);disk(.72,.022,-.205,metal);
for(const [x,y] of [[0,0],[.22,0],[-.22,0],[0,.22],[0,-.22]]){
 const sensor=disk(.072,.012,-.223,black);sensor.position.x=x;sensor.position.y=y;
 const lens=disk(.043,.008,-.233,new T.MeshStandardMaterial({color:0x34463d,metalness:.5,roughness:.2}));lens.position.x=x;lens.position.y=y;
}
for(const x of [-.09,.09]){const contact=disk(.052,.01,-.197,new T.MeshStandardMaterial({color:0xd8b350,metalness:.8,roughness:.3}));contact.position.set(x,-.91,-.197)}
// Rounded dark-metal buckle, real open aperture, pivot bar and bent tang.
const buckle=new T.Group();watch.add(buckle);buckle.position.set(0,0,-3.59);
const frameShape=roundedPath(new T.Shape(),-.62,-.40,1.24,.80,.14);
frameShape.holes.push(roundedPath(new T.Path(),-.49,-.29,.98,.58,.075));
const frame=mesh(new T.ExtrudeGeometry(frameShape,{depth:.075,bevelEnabled:true,bevelThickness:.018,bevelSize:.018,bevelSegments:4,steps:1}),metal,buckle);
frame.position.z=-.04;
const axle=mesh(new T.CylinderGeometry(.038,.038,1.10,32),silver,buckle);axle.rotation.z=Math.PI/2;axle.position.set(0,.29,0);
for(const x of [-.48,.48]){const sleeve=mesh(new T.CylinderGeometry(.064,.064,.13,32),metal,buckle);sleeve.rotation.z=Math.PI/2;sleeve.position.set(x,.29,0);}
const tangPath=new T.CatmullRomCurve3([new T.Vector3(0,.29,-.01),new T.Vector3(0,.15,-.065),new T.Vector3(0,-.14,-.075),new T.Vector3(0,-.30,-.025)]);
const tang=mesh(new T.TubeGeometry(tangPath,24,.037,10,false),silver,buckle);tang.scale.x=1.35;
// Small spring-bar release tabs at both strap attachments.
for(const sign of [-1,1]){const tab=mesh(new T.CapsuleGeometry(.023,.09,4,8),silver);tab.position.set(.37*sign,1.39*sign,-.245);}
// Center rotation in the middle of the strap loop, rather than the dial.
for (const part of watch.children) part.position.z += 1.55;
watch.position.z=-.6;
let auto=true,drag=false,lastX=0,lastY=0,ry=-.38,rx=.12,zoom=12,target=null;watch.rotation.set(rx,ry,-.07);document.querySelector('#auto').onclick=()=>{auto=!auto;document.querySelector('#auto').textContent=auto?'Dừng xoay':'Tự xoay';document.querySelector('#auto').classList.toggle('active',auto)};function view(y){auto=false;target=y;rx=.06;document.querySelector('#auto').textContent='Tự xoay';document.querySelector('#auto').classList.remove('active')}document.querySelector('#front').onclick=()=>view(0);document.querySelector('#back').onclick=()=>view(Math.PI);stage.onpointerdown=e=>{drag=true;target=null;lastX=e.clientX;lastY=e.clientY;stage.setPointerCapture(e.pointerId)};stage.onpointermove=e=>{if(!drag)return;ry+=(e.clientX-lastX)*.008;rx=Math.max(-1,Math.min(1,rx+(e.clientY-lastY)*.006));lastX=e.clientX;lastY=e.clientY};stage.onpointerup=()=>drag=false;stage.addEventListener('wheel',e=>{e.preventDefault();zoom=Math.max(7,Math.min(17,zoom+e.deltaY*.008))},{passive:false});function resize(){const w=stage.clientWidth,h=stage.clientHeight;renderer.setSize(w,h);camera.aspect=w/h;camera.updateProjectionMatrix();watch.position.set(w>700?1.35:0,w>700?0:-.45,-.6);zoom=window.WATCH_ZOOM||(w>700?12:14.5)}window.addEventListener('resize',resize);resize();let prev=0;function animate(t){const dt=Math.min((t-prev)/1000,.05);prev=t;if(auto&&!drag)ry+=dt*.3;if(target!==null){ry+=(target-ry)*.07;if(Math.abs(target-ry)<.002)target=null}watch.rotation.set(rx,ry,-.07);watch.position.y+=(Math.sin(t*.0008)*.025+ (stage.clientWidth>700?0:-.45)-watch.position.y)*.04;camera.position.z+=(zoom-camera.position.z)*.1;renderer.render(scene,camera);requestAnimationFrame(animate)}requestAnimationFrame(animate);
