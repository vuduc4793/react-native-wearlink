import * as T from '../three.module.js';
const stage=document.querySelector('#stage');let renderer;try{renderer=new T.WebGLRenderer({antialias:true,alpha:true})}catch(e){document.querySelector('#error').style.display='block';throw e}renderer.setPixelRatio(Math.min(devicePixelRatio,2));renderer.setClearColor(0,0);renderer.toneMapping=T.ACESFilmicToneMapping;renderer.toneMappingExposure=1.1;stage.appendChild(renderer.domElement);
const scene=new T.Scene(),camera=new T.PerspectiveCamera(34,1,.1,100);camera.position.z=11;
scene.add(new T.HemisphereLight(0xffffff,0x77716b,2));
const studio=new T.Scene();studio.background=new T.Color(0xaaaaaa);
for(const [x,y,z,w,h,color] of [[-4,1,4,2,7,0xffffff],[4,3,2,3,6,0xfff6e3],[0,5,-3,6,2,0xffffff],[-3,-2,-4,1,5,0xffffff]]){const panel=new T.Mesh(new T.PlaneGeometry(w,h),new T.MeshBasicMaterial({color}));panel.position.set(x,y,z);panel.lookAt(0,0,0);studio.add(panel)}
const pmrem=new T.PMREMGenerator(renderer);const env=pmrem.fromScene(studio,.025);scene.environment=env.texture;pmrem.dispose();
const ring=new T.Group();scene.add(ring);
const bodyMaterial=new T.MeshStandardMaterial({color:0x242728,metalness:.45,roughness:.4});
const insetMaterial=new T.MeshStandardMaterial({color:0x292c2b,metalness:.12,roughness:.64});
const textile=new T.MeshPhysicalMaterial({color:0x68695f,roughness:.9,metalness:0,sheen:1,sheenColor:new T.Color(0x9a998b),sheenRoughness:.8});
const thread=new T.MeshStandardMaterial({color:0x969788,metalness:.12,roughness:.68});
const darkThread=new T.MeshStandardMaterial({color:0x54574f,roughness:.9});
function add(geometry,material,parent=ring){const m=new T.Mesh(geometry,material);parent.add(m);return m}
function roundedShape(w,h,r){const p=new T.Shape(),x=-w/2,y=-h/2;p.moveTo(x+r,y);p.lineTo(x+w-r,y);p.quadraticCurveTo(x+w,y,x+w,y+r);p.lineTo(x+w,y+h-r);p.quadraticCurveTo(x+w,y+h,x+w-r,y+h);p.lineTo(x+r,y+h);p.quadraticCurveTo(x,y+h,x,y+h-r);p.lineTo(x,y+r);p.quadraticCurveTo(x,y,x+r,y);return p;}
function roundedBlock(w,h,depth,r,material){return add(new T.ExtrudeGeometry(roundedShape(w,h,r),{depth,bevelEnabled:true,bevelSize:.035,bevelThickness:.035,bevelSegments:4,steps:1,curveSegments:16}),material)}
// Long black body, blank face and softly rounded sidewalls from the photographs.
const body=roundedBlock(.80,2.08,.16,.20,bodyMaterial);body.position.z=1.13;
const face=roundedBlock(.69,1.89,.018,.16,insetMaterial);face.position.z=1.314;
const rear=roundedBlock(.70,1.90,.025,.15,bodyMaterial);rear.position.z=1.08;
const start=.70,end=Math.PI*2-.70;
function point(x,a,offset=0){return new T.Vector3(x,Math.sin(a)*(1.72+offset),Math.cos(a)*(1.47+offset));}
function band(a0,a1,offset=0){const v=[],indices=[],N=280;for(let i=0;i<=N;i++){const a=a0+(a1-a0)*i/N;for(const x of [-.355,.355])v.push(...point(x,a,offset).toArray());}for(let i=0;i<N;i++){const j=i*2;indices.push(j,j+1,j+2,j+1,j+3,j+2)}const g=new T.BufferGeometry();g.setAttribute('position',new T.Float32BufferAttribute(v,3));g.setIndex(indices);g.computeVertexNormals();const mat=textile.clone();mat.side=T.DoubleSide;add(g,mat);}
band(start,end);
// Interlaced strands are real geometry, so the texture remains visible in profile.
for(let row=0;row<190;row++){
 const a=start+(end-start)*row/189,pts=[];
 for(let col=0;col<=28;col++){const x=-.355+.71*col/28;const weave=Math.sin(col*Math.PI/2+row*Math.PI)*.007;pts.push(point(x,a+Math.sin(col*Math.PI)*.004,.011+weave));}
 add(new T.TubeGeometry(new T.CatmullRomCurve3(pts),40,.009,5,false),row%3===0?darkThread:thread);
}
for(let col=0;col<22;col++){
 const pts=[],x=-.355+.71*col/21;for(let row=0;row<=380;row++){const a=start+(end-start)*row/380;pts.push(point(x,a,.008+Math.cos(row*Math.PI/2+col*Math.PI)*.007));}
 add(new T.TubeGeometry(new T.CatmullRomCurve3(pts),380,.007,5,false),darkThread);
}
// Bound fabric edges and the folded-over strap end.
for(const x of [-.36,.36]){const pts=[];for(let i=0;i<=280;i++)pts.push(point(x,start+(end-start)*i/280,.004));add(new T.TubeGeometry(new T.CatmullRomCurve3(pts),280,.018,8,false),darkThread);}
band(3.35,5.55,-.045);
for(let row=0;row<80;row++){const a=3.35+(5.55-3.35)*row/79,pts=[];for(let i=0;i<=18;i++)pts.push(point(-.35+.70*i/18,a,-.047+Math.sin(i*Math.PI/2+row*Math.PI)*.006));add(new T.TubeGeometry(new T.CatmullRomCurve3(pts),28,.008,5,false),thread);}
// Visible U-shaped guide around the top end of the body.
const guidePoints=[[-.44,.91,1.32],[-.44,1.10,1.32],[-.37,1.20,1.32],[0,1.215,1.32],[.37,1.20,1.32],[.44,1.10,1.32],[.44,.91,1.32]].map(p=>new T.Vector3(...p));
add(new T.TubeGeometry(new T.CatmullRomCurve3(guidePoints),72,.043,12,false),bodyMaterial);
for(const sign of [-1,1]){const anchor=roundedBlock(.68,.17,.07,.035,bodyMaterial);anchor.position.set(0,sign*1.04,1.06);anchor.rotation.x=sign*.18;}
let auto=true,drag=false,lastX=0,lastY=0,ry=-.6,rx=.14,zoom=11,target=null;const autoButton=document.querySelector('#auto');function setAuto(value){auto=value;autoButton.textContent=auto?'Dừng xoay':'Tự xoay';autoButton.classList.toggle('active',auto)}autoButton.onclick=()=>setAuto(!auto);function view(x,y){setAuto(false);target={x,y}}document.querySelector('#front').onclick=()=>view(.14,-.6);document.querySelector('#back').onclick=()=>view(.12,Math.PI-.5);
stage.onpointerdown=e=>{drag=true;target=null;lastX=e.clientX;lastY=e.clientY;stage.setPointerCapture(e.pointerId)};stage.onpointermove=e=>{if(!drag)return;ry+=(e.clientX-lastX)*.008;rx+=(e.clientY-lastY)*.008;lastX=e.clientX;lastY=e.clientY};stage.onpointerup=stage.onpointercancel=()=>drag=false;stage.addEventListener('wheel',e=>{e.preventDefault();zoom=Math.max(7,Math.min(17,zoom+e.deltaY*.008))},{passive:false});function resize(){const w=stage.clientWidth,h=stage.clientHeight;renderer.setSize(w,h);camera.aspect=w/h;camera.updateProjectionMatrix();ring.position.set(w>700?1.2:0,w>700?0:-.5,0);zoom=window.WATCH_ZOOM||(w>700?11:12.5)}window.addEventListener('resize',resize);resize();let previous=0;function animate(t){const dt=Math.min((t-previous)/1000,.05);previous=t;if(auto&&!drag)ry+=dt*.27;if(target){rx+=(target.x-rx)*.08;ry+=(target.y-ry)*.08;if(Math.abs(rx-target.x)+Math.abs(ry-target.y)<.001)target=null}ring.rotation.set(rx,ry,-.08);camera.position.z+=(zoom-camera.position.z)*.12;renderer.render(scene,camera);requestAnimationFrame(animate)}requestAnimationFrame(animate);
