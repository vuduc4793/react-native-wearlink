import * as T from '../three.module.js';
const stage=document.querySelector('#stage');let renderer;try{renderer=new T.WebGLRenderer({antialias:true,alpha:true})}catch(e){document.querySelector('#error').style.display='block';throw e}renderer.setPixelRatio(Math.min(devicePixelRatio,2));renderer.setClearColor(0,0);renderer.toneMapping=T.ACESFilmicToneMapping;renderer.toneMappingExposure=1.1;stage.appendChild(renderer.domElement);
const scene=new T.Scene(),camera=new T.PerspectiveCamera(34,1,.1,100);camera.position.z=11;
scene.add(new T.HemisphereLight(0xffffff,0x77716b,2));
const studio=new T.Scene();studio.background=new T.Color(0xaaaaaa);
for(const [x,y,z,w,h,color] of [[-4,1,4,2,7,0xffffff],[4,3,2,3,6,0xfff6e3],[0,5,-3,6,2,0xffffff],[-3,-2,-4,1,5,0xffffff]]){const panel=new T.Mesh(new T.PlaneGeometry(w,h),new T.MeshBasicMaterial({color}));panel.position.set(x,y,z);panel.lookAt(0,0,0);studio.add(panel)}
const pmrem=new T.PMREMGenerator(renderer);const env=pmrem.fromScene(studio,.025);scene.environment=env.texture;pmrem.dispose();
const ring=new T.Group();scene.add(ring);
const gold=new T.MeshStandardMaterial({color:0xdcc18a,metalness:1,roughness:.15,envMapIntensity:1.65});
const liner=new T.MeshPhysicalMaterial({color:0x101314,metalness:.18,roughness:.15,clearcoat:1,clearcoatRoughness:.1});
const silver=new T.MeshStandardMaterial({color:0xbebfbd,metalness:.85,roughness:.23});
function add(geometry,material,parent=ring){const m=new T.Mesh(geometry,material);parent.add(m);return m}
function lathe(points,material){const m=add(new T.LatheGeometry(points.map(p=>new T.Vector2(...p)),192),material);m.rotation.x=Math.PI/2;return m}
// Broad polished outer band with gently crowned surface and rounded edges.
lathe([[1.435,-.355],[1.565,-.355],[1.606,-.345],[1.633,-.32],[1.642,-.275],[1.65,-.15],[1.653,0],[1.65,.15],[1.642,.275],[1.633,.32],[1.606,.345],[1.565,.355],[1.435,.355],[1.435,-.355]],gold);
lathe([[1.438,-.35],[1.438,.35],[1.406,.35],[1.385,.325],[1.375,.27],[1.374,-.27],[1.385,-.325],[1.406,-.35],[1.438,-.35]],liner);
for(const z of [-.32,.32]){const seam=add(new T.TorusGeometry(1.414,.012,8,192),liner);seam.position.z=z}
// Sensor modules are mounted on the inner circumference, facing the finger.
function inside(angle,radius=1.371){const group=new T.Group();ring.add(group);group.position.set(Math.cos(angle)*radius,Math.sin(angle)*radius,0);const basis=new T.Matrix4().makeBasis(new T.Vector3(Math.sin(angle),-Math.cos(angle),0),new T.Vector3(0,0,1),new T.Vector3(-Math.cos(angle),-Math.sin(angle),0));group.quaternion.setFromRotationMatrix(basis);return group}
const glass=new T.MeshPhysicalMaterial({color:0x15201d,metalness:.1,roughness:.12,clearcoat:1});
for(const [angle,color] of [[-1.08,0x4a9a53],[-2.02,0x9c3539]]){
 const module=inside(angle);add(new T.BoxGeometry(.29,.45,.035),liner,module);
 const lens=add(new T.SphereGeometry(1,32,16),glass,module);lens.scale.set(.125,.19,.035);lens.position.z=.031;
 for(const x of [-.055,.055]){const diode=add(new T.BoxGeometry(.065,.09,.008),new T.MeshStandardMaterial({color,metalness:.25,roughness:.2,emissive:color,emissiveIntensity:.12}),module);diode.position.set(x,0,.066)}
}
const contact=inside(-2.65);const coin=add(new T.CylinderGeometry(.17,.17,.014,64),silver,contact);coin.rotation.x=Math.PI/2;coin.position.z=.014;const center=add(new T.CircleGeometry(.105,48),liner,contact);center.position.z=.023;const dot=add(new T.CircleGeometry(.047,32),silver,contact);dot.position.z=.025;
const chip=inside(-1.56);add(new T.BoxGeometry(.21,.25,.018),new T.MeshStandardMaterial({color:0xb5a477,metalness:.65,roughness:.4}),chip).position.z=.012;
for(const a of [-1.36,-1.76])for(const z of [-.2,.2]){const pad=inside(a);const p=add(new T.CircleGeometry(.025,16),silver,pad);p.position.set(0,z,.006)}
// Small inner marking, following the curvature rather than floating off the ring.
const labelCanvas=document.createElement('canvas');labelCanvas.width=1024;labelCanvas.height=128;const ctx=labelCanvas.getContext('2d');ctx.fillStyle='#111415';ctx.fillRect(0,0,1024,128);ctx.fillStyle='#b5b5af';ctx.font='48px Arial';ctx.textAlign='center';ctx.fillText('Smart Ring   7',512,85);const labelTexture=new T.CanvasTexture(labelCanvas);labelTexture.colorSpace=T.SRGBColorSpace;
const vertices=[],uv=[],indices=[];const segments=80;for(let i=0;i<=segments;i++){const a=.5+i/segments*1.05;for(const z of [-.11,.11]){vertices.push(Math.cos(a)*1.372,Math.sin(a)*1.372,z);uv.push(i/segments,z<0?0:1)}}for(let i=0;i<segments;i++){const j=i*2;indices.push(j,j+2,j+1,j+1,j+2,j+3)}const labelGeo=new T.BufferGeometry();labelGeo.setAttribute('position',new T.Float32BufferAttribute(vertices,3));labelGeo.setAttribute('uv',new T.Float32BufferAttribute(uv,2));labelGeo.setIndex(indices);labelGeo.computeVertexNormals();add(labelGeo,new T.MeshBasicMaterial({map:labelTexture,side:T.DoubleSide}));
let auto=true,drag=false,lastX=0,lastY=0,ry=-.55,rx=.38,zoom=11,target=null;const autoButton=document.querySelector('#auto');function setAuto(value){auto=value;autoButton.textContent=auto?'Dừng xoay':'Tự xoay';autoButton.classList.toggle('active',auto)}autoButton.onclick=()=>setAuto(!auto);function view(x,y){setAuto(false);target={x,y}}document.querySelector('#front').onclick=()=>view(.38,-.65);document.querySelector('#back').onclick=()=>view(1.12,-.4);
stage.onpointerdown=e=>{drag=true;target=null;lastX=e.clientX;lastY=e.clientY;stage.setPointerCapture(e.pointerId)};stage.onpointermove=e=>{if(!drag)return;ry+=(e.clientX-lastX)*.008;rx+=(e.clientY-lastY)*.008;lastX=e.clientX;lastY=e.clientY};stage.onpointerup=stage.onpointercancel=()=>drag=false;stage.addEventListener('wheel',e=>{e.preventDefault();zoom=Math.max(7,Math.min(17,zoom+e.deltaY*.008))},{passive:false});function resize(){const w=stage.clientWidth,h=stage.clientHeight;renderer.setSize(w,h);camera.aspect=w/h;camera.updateProjectionMatrix();ring.position.set(w>700?1.2:0,w>700?0:-.5,0);zoom=window.WATCH_ZOOM||(w>700?11:12.5)}window.addEventListener('resize',resize);resize();let previous=0;function animate(t){const dt=Math.min((t-previous)/1000,.05);previous=t;if(auto&&!drag)ry+=dt*.27;if(target){rx+=(target.x-rx)*.08;ry+=(target.y-ry)*.08;if(Math.abs(rx-target.x)+Math.abs(ry-target.y)<.001)target=null}ring.rotation.set(rx,ry,-.13);camera.position.z+=(zoom-camera.position.z)*.12;renderer.render(scene,camera);requestAnimationFrame(animate)}requestAnimationFrame(animate);
