import * as T from '../three.module.js';
const stage=document.querySelector('#stage');let renderer;try{renderer=new T.WebGLRenderer({antialias:true,alpha:true})}catch(e){document.querySelector('#error').style.display='block';throw e}renderer.setPixelRatio(Math.min(devicePixelRatio,2));renderer.setClearColor(0,0);renderer.toneMapping=T.ACESFilmicToneMapping;renderer.toneMappingExposure=1.1;stage.appendChild(renderer.domElement);
const scene=new T.Scene(),camera=new T.PerspectiveCamera(34,1,.1,100);camera.position.z=11;
scene.add(new T.HemisphereLight(0xffffff,0x77716b,2));
const studio=new T.Scene();studio.background=new T.Color(0xaaaaaa);
for(const [x,y,z,w,h,color] of [[-4,1,4,2,7,0xffffff],[4,3,2,3,6,0xfff6e3],[0,5,-3,6,2,0xffffff],[-3,-2,-4,1,5,0xffffff]]){const panel=new T.Mesh(new T.PlaneGeometry(w,h),new T.MeshBasicMaterial({color}));panel.position.set(x,y,z);panel.lookAt(0,0,0);studio.add(panel)}
const pmrem=new T.PMREMGenerator(renderer);const env=pmrem.fromScene(studio,.025);scene.environment=env.texture;pmrem.dispose();
const ring=new T.Group();scene.add(ring);
const bodyMaterial=new T.MeshStandardMaterial({color:0x555c65,metalness:.72,roughness:.3});
const insetMaterial=new T.MeshStandardMaterial({color:0x292c2b,metalness:.12,roughness:.64});
const textile=new T.MeshPhysicalMaterial({color:0x141617,roughness:.9,metalness:0,sheen:1,sheenColor:new T.Color(0x363839),sheenRoughness:.8});
const thread=new T.MeshStandardMaterial({color:0x45484a,metalness:0,roughness:.75});
const darkThread=new T.MeshStandardMaterial({color:0x131516,roughness:.9});
function add(geometry,material,parent=ring){const m=new T.Mesh(geometry,material);parent.add(m);return m}
function roundedShape(w,h,r){const p=new T.Shape(),x=-w/2,y=-h/2;p.moveTo(x+r,y);p.lineTo(x+w-r,y);p.quadraticCurveTo(x+w,y,x+w,y+r);p.lineTo(x+w,y+h-r);p.quadraticCurveTo(x+w,y+h,x+w-r,y+h);p.lineTo(x+r,y+h);p.quadraticCurveTo(x,y+h,x,y+h-r);p.lineTo(x,y+r);p.quadraticCurveTo(x,y,x+r,y);return p;}
function roundedBlock(w,h,depth,r,material){return add(new T.ExtrudeGeometry(roundedShape(w,h,r),{depth,bevelEnabled:true,bevelSize:.035,bevelThickness:.035,bevelSegments:4,steps:1,curveSegments:16}),material)}
// Long black body, blank face and softly rounded sidewalls from the photographs.
const body=roundedBlock(.96,2.08,.18,.18,bodyMaterial);body.position.z=1.13;


// A SINGLE ribbon: anchored at rear loop, over the capsule, around wrist,
// through the loop, around its crossbar and reversed into a returned tail.
// The entire ribbon follows one wrist ellipse, including the section over the device.
// One ellipse over the entire wrist: no blended sections or inflection points.
function frontPoint(x,a,offset=0){return new T.Vector3(x,Math.sin(a)*1.72,Math.cos(a)*1.47+offset);}
// Two analytic arcs trace the red outline: slim at center and smoothly thinner at ends.
function housingArcs(y){
 const outer=Math.sqrt(Math.max(.001,1-(y/1.72)**2));
 const inner=Math.sqrt(Math.max(.001,1-(y/1.96)**2));
 const upper=1.45*outer,previousLower=1.33*inner;
 return {upper,lower:upper-(upper-previousLower)*1.15};
}
const ribbonEnd=1.47;
const rearDelta=Math.asin(.13/1.72),rearZ=-Math.cos(rearDelta)*1.47;
function ribbonPoint(x,t){
 // Fixed end is folded and sewn around the LOWER side of the ring.
 if(t<=.06){
 const u=t/.06,a=Math.PI+Math.asin(.43/1.72)*(1-u)+rearDelta*u;
 const p=frontPoint(x,a);p.y+=Math.sin(a)*.038;p.z+=Math.cos(a)*.038;return p;
}
 if(t<=.11){const u=(t-.06)/.05;return new T.Vector3(x,-.13+.019*Math.sin(Math.PI*u),rearZ-.038+.038*(1-Math.cos(Math.PI*u))/2);}
 // Main length: down around wrist, through the body, then back to ring.
 if(t<=1.11){const u=(t-.11);return frontPoint(x,Math.PI+rearDelta+(2*Math.PI-2*rearDelta)*u);}
 // Free end passes through the opening and doubles back over UPPER side.
 if(t<=1.16){const u=(t-1.11)/.05;return new T.Vector3(x,.13-.019*Math.sin(Math.PI*u),rearZ-.038*(1-Math.cos(Math.PI*u))/2);}
 const u=(t-1.16)/.31,a=(3*Math.PI-rearDelta)-u*(.32*Math.PI-rearDelta);
 const p=frontPoint(x,a);p.y+=Math.sin(a)*.038;p.z+=Math.cos(a)*.038;return p;
}
function ribbonFrame(x,t,offset=0){
 const position=ribbonPoint(x,t),lo=Math.max(0,t-.0001),hi=Math.min(ribbonEnd,t+.0001);
 const tangent=ribbonPoint(0,hi).sub(ribbonPoint(0,lo)).normalize();
 const normal=new T.Vector3(0,-tangent.z,tangent.y);position.addScaledVector(normal,offset);
 return {position,tangent,normal};
}
const fabricParts=new Set();
function ribbonSurface(){
 const v=[],indices=[],N=820;
 // Closed thickness around the entire path, including the hairpin turn.
 for(let i=0;i<=N;i++)for(const [x,offset] of [[-.405,.010],[.405,.010],[-.405,-.010],[.405,-.010]])v.push(...ribbonFrame(x,ribbonEnd*i/N,offset).position.toArray());
 for(let i=0;i<N;i++){const j=i*4,k=j+4;indices.push(j,k,j+1,j+1,k,k+1,j+2,j+3,k+2,j+3,k+3,k+2,j,j+2,k,j+2,k+2,k,j+1,k+1,j+3,j+3,k+1,k+3);}
 indices.push(0,1,2,1,3,2);const q=N*4;indices.push(q,q+2,q+1,q+1,q+2,q+3);
 const g=new T.BufferGeometry();g.setAttribute('position',new T.Float32BufferAttribute(v,3));g.setIndex(indices);g.computeVertexNormals();const m=add(g,textile);fabricParts.add(m);
}
ribbonSurface();
// Short interlaced fibers form a visible directional weave, rather than parallel ribs.
const fiberGeometry=new T.CapsuleGeometry(.007,.032,2,5);
const fiberMaterial=new T.MeshStandardMaterial({color:0xffffff,roughness:.76,metalness:0});
function wovenPatch(columns,rows,positionAt){
 const fibers=new T.InstancedMesh(fiberGeometry,fiberMaterial,columns*rows);
 const matrix=new T.Matrix4(),basis=new T.Matrix4(),tilt=new T.Matrix4(),scale=new T.Matrix4().makeScale(1,1,.62);
 for(let row=0;row<rows;row++)for(let col=0;col<columns;col++){
  const cell=(Math.floor((col+row*.48)/5)%2),angle=cell?.72:-.72;
  const {position,tangent,normal}=positionAt(col/(columns-1),row/(rows-1));
  basis.makeBasis(new T.Vector3(1,0,0),tangent,normal);tilt.makeRotationZ(angle);
  matrix.copy(basis).multiply(tilt).multiply(scale);matrix.setPosition(position);const i=row*columns+col;fibers.setMatrixAt(i,matrix);
  const shade=[0x303335,0x3d4042,0x505355,0x343739][(row+col*3)%4];fibers.setColorAt(i,new T.Color(shade));
 }
 fibers.instanceMatrix.needsUpdate=true;fibers.instanceColor.needsUpdate=true;ring.add(fibers);
}
wovenPatch(29,390,(u,v)=>ribbonFrame(-.40+.80*u,ribbonEnd*v,.017));fabricParts.add(ring.children.at(-1));
wovenPatch(29,390,(u,v)=>{const f=ribbonFrame(-.40+.80*u,ribbonEnd*v,-.017);f.tangent.negate();f.normal.negate();return f;});fabricParts.add(ring.children.at(-1));
for(const x of [-.411,.411]){
 const pts=[];for(let i=0;i<=820;i++)pts.push(ribbonFrame(x,ribbonEnd*i/820).position);
 const edge=add(new T.TubeGeometry(new T.CatmullRomCurve3(pts),820,.014,8,false),darkThread);fabricParts.add(edge);
}
const topRails=new Set();
for(const sign of [-1,1]){
 const rail=add(new T.ExtrudeGeometry(roundedShape(.86,.10,.035),{depth:.030,bevelEnabled:true,bevelSize:.010,bevelThickness:.010,bevelSegments:3,curveSegments:12}),bodyMaterial);rail.position.set(0,sign*.995,1.39);topRails.add(rail);

}
// Side inset, elongated button and green indicator sit flush with the right wall.
const sideMaterial=new T.MeshStandardMaterial({color:0xa0a4a9,metalness:.6,roughness:.32});
// The right wall is the housing itself; there is no separate raised side plate.
const buttonMaterial=new T.MeshStandardMaterial({color:0xe0e1df,metalness:.3,roughness:.35});
const electrodeGeometry=new T.ExtrudeGeometry(roundedShape(.075,.43,.0375),{depth:.003,bevelEnabled:true,bevelSize:.001,bevelThickness:.001,bevelSegments:2,curveSegments:16});
const electrode=add(electrodeGeometry,buttonMaterial);electrode.rotation.y=Math.PI/2;electrode.position.set(.516,-.17,1.22);
const led=add(new T.SphereGeometry(.020,20,12),new T.MeshStandardMaterial({color:0x61e321,emissive:0x54f51b,emissiveIntensity:1,roughness:.25}));led.scale.x=.30;led.position.set(.518,.43,1.22);
// Rectangular optical window follows the underside shown in the new reference.
const darkGlass=new T.MeshPhysicalMaterial({color:0x080e0d,metalness:.1,roughness:.12,clearcoat:1});
const sensor=roundedBlock(.49,1.12,.014,.075,darkGlass);sensor.position.set(0,-.01,1.045);
function rearPatch(w,h,x,y,z,material,r=.02){const patch=add(new T.ShapeGeometry(roundedShape(w,h,r)),material);patch.rotation.y=Math.PI;patch.position.set(x,y,z);return patch;}
const sensorSilver=new T.MeshStandardMaterial({color:0xa3a8a7,metalness:.65,roughness:.28,side:T.DoubleSide});
for(const y of [-.33,.31])rearPatch(.31,.12,0,y,1.006,sensorSilver,.025);
rearPatch(.31,.32,0,-.02,1.005,new T.MeshPhysicalMaterial({color:0x152c20,roughness:.15,clearcoat:1,side:T.DoubleSide}),.025);
for(const x of [-.09,.09])rearPatch(.065,.065,x,-.015,1.003,new T.MeshStandardMaterial({color:0x51874d,emissive:0x205c18,emissiveIntensity:.3,roughness:.25,side:T.DoubleSide}),.014);
for(const x of [-.07,.07]){const contact=add(new T.CircleGeometry(.022,24),new T.MeshStandardMaterial({color:0xdac27d,metalness:.85,roughness:.3}));contact.rotation.y=Math.PI;contact.position.set(x,-.72,1.04);}
// Curve the complete capsule and its details to match the band profile.
for(const part of ring.children){
 if(fabricParts.has(part))continue;
 part.updateMatrix();const original=part.geometry.index?part.geometry.toNonIndexed():part.geometry;
 const positions=original.attributes.position,refined=[];
 function subdivide(a,b,c){
  const e=[[a,b,c],[b,c,a],[c,a,b]].sort((u,v)=>Math.abs(v[0][1]-v[1][1])-Math.abs(u[0][1]-u[1][1]));const [p,q,r]=e[0];
  if(Math.abs(p[1]-q[1])>.085){const m=p.map((v,i)=>(v+q[i])/2);subdivide(p,m,r);subdivide(m,q,r);}else refined.push(...a,...b,...c);
 }
 for(let i=0;i<positions.count;i+=3){const tri=[0,1,2].map(j=>new T.Vector3().fromBufferAttribute(positions,i+j).applyMatrix4(part.matrix).toArray());subdivide(...tri);}
 const g=new T.BufferGeometry();g.setAttribute('position',new T.Float32BufferAttribute(refined,3));const pv=g.attributes.position;
 for(let i=0;i<pv.count;i++){
 const y=pv.getY(i),z=pv.getZ(i),{upper,lower}=housingArcs(y);
 if(topRails.has(part))pv.setZ(i,upper+.01+(z-1.39)*.8);
 else {
  const depthFraction=(z-1.095)/.25;
  pv.setZ(i,lower+(upper-lower)*depthFraction);
 }
}g.computeVertexNormals();part.geometry=g;part.position.set(0,0,0);part.rotation.set(0,0,0);part.scale.set(1,1,1);
}
// Polished rounded rectangular adjustment loop on the rear of the strap.
const loopMaterial=new T.MeshStandardMaterial({color:0x888b8c,metalness:.95,roughness:.18});
const loopPath=new T.CurvePath();
const loopPts=[[-.43,-.13,-1.49],[-.51,-.08,-1.49],[-.51,.08,-1.49],[-.43,.13,-1.49],[.43,.13,-1.49],[.51,.08,-1.49],[.51,-.08,-1.49],[.43,-.13,-1.49],[-.43,-.13,-1.49]].map(p=>new T.Vector3(...p));
const loopCurve=new T.CatmullRomCurve3(loopPts,true,'centripetal');
add(new T.TubeGeometry(loopCurve,100,.032,10,true),loopMaterial);
// No central divider: fixed eye and free return use opposite sides of one loop.
const stitchMaterial=new T.MeshStandardMaterial({color:0x505355,roughness:.9});
for(let i=0;i<16;i++){
 const stitch=add(new T.CapsuleGeometry(.004,.025,2,4),stitchMaterial);
 stitch.rotation.z=Math.PI/2;stitch.position.set(-.37+.74*i/15,-.40,rearZ-.05);
}
let auto=true,drag=false,lastX=0,lastY=0,ry=-.6,rx=.14,zoom=11,target=null;const autoButton=document.querySelector('#auto');function setAuto(value){auto=value;autoButton.textContent=auto?'Dừng xoay':'Tự xoay';autoButton.classList.toggle('active',auto)}autoButton.onclick=()=>setAuto(!auto);function view(x,y){setAuto(false);target={x,y}}document.querySelector('#front').onclick=()=>view(.14,-.6);document.querySelector('#back').onclick=()=>view(.12,Math.PI-.5);
stage.onpointerdown=e=>{drag=true;target=null;lastX=e.clientX;lastY=e.clientY;stage.setPointerCapture(e.pointerId)};stage.onpointermove=e=>{if(!drag)return;ry+=(e.clientX-lastX)*.008;rx+=(e.clientY-lastY)*.008;lastX=e.clientX;lastY=e.clientY};stage.onpointerup=stage.onpointercancel=()=>drag=false;stage.addEventListener('wheel',e=>{e.preventDefault();zoom=Math.max(7,Math.min(17,zoom+e.deltaY*.008))},{passive:false});function resize(){const w=stage.clientWidth,h=stage.clientHeight;renderer.setSize(w,h);camera.aspect=w/h;camera.updateProjectionMatrix();ring.position.set(w>700?1.2:0,w>700?0:-.5,0);zoom=window.WATCH_ZOOM||(w>700?11:12.5)}window.addEventListener('resize',resize);resize();let previous=0;function animate(t){const dt=Math.min((t-previous)/1000,.05);previous=t;if(auto&&!drag)ry+=dt*.27;if(target){rx+=(target.x-rx)*.08;ry+=(target.y-ry)*.08;if(Math.abs(rx-target.x)+Math.abs(ry-target.y)<.001)target=null}ring.rotation.set(rx,ry,-.08);camera.position.z+=(zoom-camera.position.z)*.12;renderer.render(scene,camera);requestAnimationFrame(animate)}requestAnimationFrame(animate);
