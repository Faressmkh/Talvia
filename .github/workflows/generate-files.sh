#!/bin/bash

# Create directories
mkdir -p backend/src/{config,routes,middleware,utils}
mkdir -p frontend/src/{pages,components,store,types}

# Backend files
cat > backend/tsconfig.json << 'EOF'
{"compilerOptions":{"target":"ES2020","module":"ESNext","lib":["ES2020"],"outDir":"./dist","rootDir":"./src","strict":true,"esModuleInterop":true,"skipLibCheck":true,"forceConsistentCasingInFileNames":true,"resolveJsonModule":true,"declaration":true,"declarationMap":true,"sourceMap":true,"moduleResolution":"node"},"include":["src/**/*"],"exclude":["node_modules"]}
EOF

cat > backend/.env.example << 'EOF'
NODE_ENV=production
PORT=3000
DATABASE_URL=postgresql://postgres:password@postgres:5432/talvia
JWT_SECRET=your_jwt_secret_key_here
GOOGLE_CLIENT_ID=your_google_client_id
GOOGLE_CLIENT_SECRET=your_google_client_secret
GOOGLE_CALLBACK_URL=https://your-domain.up.railway.app/auth/google/callback
LINKEDIN_CLIENT_ID=your_linkedin_client_id
LINKEDIN_CLIENT_SECRET=your_linkedin_client_secret
LINKEDIN_CALLBACK_URL=https://your-domain.up.railway.app/auth/linkedin/callback
BUCKET_ENDPOINT=https://bucket-endpoint
BUCKET_ACCESS_KEY=your_access_key
BUCKET_SECRET_KEY=your_secret_key
BUCKET_NAME=talvia-bucket
BUCKET_REGION=us-east-1
LIBRETRANSLATE_URL=https://libretranslate.de
FRONTEND_URL=https://your-frontend-domain.up.railway.app
ADMIN_EMAIL=faresmoukah@gmail.com
EOF

cat > backend/Dockerfile << 'EOF'
FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build
EXPOSE 3000
ENV INIT_DB=true
CMD ["npm", "start"]
EOF

cat > backend/src/config.ts << 'EOF'
import dotenv from 'dotenv';
dotenv.config();
export const config = {env:process.env.NODE_ENV||'development',port:process.env.PORT||3000,database:{url:process.env.DATABASE_URL||'postgresql://user:password@localhost:5432/talvia'},jwt:{secret:process.env.JWT_SECRET||'dev-secret-key',expiresIn:'7d'},google:{clientId:process.env.GOOGLE_CLIENT_ID||'',clientSecret:process.env.GOOGLE_CLIENT_SECRET||'',callbackUrl:process.env.GOOGLE_CALLBACK_URL||'http://localhost:3000/auth/google/callback'},linkedin:{clientId:process.env.LINKEDIN_CLIENT_ID||'',clientSecret:process.env.LINKEDIN_CLIENT_SECRET||'',callbackUrl:process.env.LINKEDIN_CALLBACK_URL||'http://localhost:3000/auth/linkedin/callback'},bucket:{endpoint:process.env.BUCKET_ENDPOINT||'',accessKey:process.env.BUCKET_ACCESS_KEY||'',secretKey:process.env.BUCKET_SECRET_KEY||'',name:process.env.BUCKET_NAME||'talvia-bucket',region:process.env.BUCKET_REGION||'us-east-1'},libretranslate:{url:process.env.LIBRETRANSLATE_URL||'https://libretranslate.de'},frontendUrl:process.env.FRONTEND_URL||'http://localhost:5173',adminEmail:process.env.ADMIN_EMAIL||'faresmoukah@gmail.com'};
EOF

cat > backend/src/db.ts << 'EOF'
import pkg from 'pg';import {config} from './config.js';const {Pool}=pkg;const pool=new Pool({connectionString:config.database.url});export async function initializeDatabase(){try{await pool.query(`CREATE TABLE IF NOT EXISTS users(id SERIAL PRIMARY KEY,email VARCHAR(255) UNIQUE NOT NULL,name VARCHAR(255) NOT NULL,role VARCHAR(50) NOT NULL CHECK(role IN('candidate','employer','admin')),oauth_provider VARCHAR(50),oauth_id VARCHAR(255),password_hash VARCHAR(255),profile_data JSONB,cv_url VARCHAR(255),cv_translated JSONB,company_id INT,created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);`);await pool.query(`CREATE TABLE IF NOT EXISTS job_offers(id SERIAL PRIMARY KEY,company_id INT NOT NULL REFERENCES users(id),title VARCHAR(255) NOT NULL,description TEXT NOT NULL,description_translated JSONB,location VARCHAR(255),salary_min DECIMAL,salary_max DECIMAL,employment_type VARCHAR(50),status VARCHAR(50) NOT NULL CHECK(status IN('pending','approved','rejected','closed')),validated_by INT,created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);`);await pool.query(`CREATE TABLE IF NOT EXISTS applications(id SERIAL PRIMARY KEY,candidate_id INT NOT NULL REFERENCES users(id),offer_id INT NOT NULL REFERENCES job_offers(id),status VARCHAR(50) NOT NULL CHECK(status IN('applied','reviewed','interview_scheduled','interview_done','accepted','rejected')),interview_date TIMESTAMP,interview_notes TEXT,applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);`);console.log('✅ Database initialized');}catch(error){console.error('❌ Database error:',error);}}export async function getPool(){return pool;}if(process.env.INIT_DB==='true'){await initializeDatabase();}
EOF

cat > backend/src/middleware/auth.ts << 'EOF'
import jwt from 'jsonwebtoken';import {config} from '../config.js';import {Request,Response,NextFunction} from 'express';declare global{namespace Express{interface Request{user?:any;}}}export function verifyToken(req:Request,res:Response,next:NextFunction){const token=req.headers.authorization?.split(' ')[1];if(!token){return res.status(401).json({error:'No token provided'});}try{const decoded=jwt.verify(token,config.jwt.secret as string);req.user=decoded;next();}catch(error){return res.status(401).json({error:'Invalid token'});}}export function generateToken(userId:number,email:string,role:string){return jwt.sign({userId,email,role},config.jwt.secret as string,{expiresIn:config.jwt.expiresIn});}export function requireRole(...roles:string[]){return(req:Request,res:Response,next:NextFunction)=>{if(!req.user||!roles.includes(req.user.role)){return res.status(403).json({error:'Access denied'});}next();};}
EOF

cat > backend/src/utils/translate.ts << 'EOF'
import axios from 'axios';import {config} from '../config.js';export async function translateText(text:string,targetLang:'fr'|'en'|'lb'):Promise<string>{try{if(targetLang==='fr')return text;const response=await axios.post(`${config.libretranslate.url}/translate`,{q:text,source:'fr',target:targetLang==='en'?'en':'lb'});return response.data.translatedText;}catch(error){console.error('Translation error:',error);return text;}}export async function translateObject(obj:any,targetLang:'fr'|'en'|'lb'):Promise<Record<string,string>>{const translated:Record<string,string>={};for(const[key,value]of Object.entries(obj)){if(typeof value==='string'){translated[key]=await translateText(value,targetLang);}}return translated;}
EOF

cat > backend/src/routes/auth.ts << 'EOF'
import express,{Request,Response} from 'express';import {getPool} from '../db.js';import {generateToken} from '../middleware/auth.js';import bcrypt from 'bcryptjs';const router=express.Router();router.get('/health',(req:Request,res:Response)=>{res.json({status:'OK'});});router.post('/register',async(req:Request,res:Response)=>{try{const{email,name,role,password}=req.body;const pool=await getPool();const hashedPassword=await bcrypt.hash(password,10);const result=await pool.query(`INSERT INTO users(email,name,role,password_hash)VALUES($1,$2,$3,$4)RETURNING id,email,role`,[email,name,role||'candidate',hashedPassword]);const user=result.rows[0];const token=generateToken(user.id,user.email,user.role);res.json({token,user});}catch(error:any){res.status(400).json({error:error.message});}});router.post('/login',async(req:Request,res:Response)=>{try{const{email,password}=req.body;const pool=await getPool();const result=await pool.query('SELECT*FROM users WHERE email=$1',[email]);if(result.rows.length===0){return res.status(401).json({error:'Invalid credentials'});}const user=result.rows[0];const validPassword=await bcrypt.compare(password,user.password_hash);if(!validPassword){return res.status(401).json({error:'Invalid credentials'});}const token=generateToken(user.id,user.email,user.role);res.json({token,user:{id:user.id,email:user.email,role:user.role,name:user.name}});}catch(error:any){res.status(400).json({error:error.message});}});export default router;
EOF

cat > backend/src/routes/offers.ts << 'EOF'
import express,{Request,Response} from 'express';import {getPool} from '../db.js';import {verifyToken,requireRole} from '../middleware/auth.js';const router=express.Router();router.get('/',async(req:Request,res:Response)=>{try{const pool=await getPool();const result=await pool.query(`SELECT id,title,description,location,salary_min,salary_max,employment_type,created_at FROM job_offers WHERE status='approved'ORDER BY created_at DESC`);res.json(result.rows);}catch(error:any){res.status(400).json({error:error.message});}});router.post('/',verifyToken,requireRole('employer'),async(req:Request,res:Response)=>{try{const{title,description,location,salary_min,salary_max,employment_type}=req.body;const pool=await getPool();const result=await pool.query(`INSERT INTO job_offers(company_id,title,description,location,salary_min,salary_max,employment_type,status)VALUES($1,$2,$3,$4,$5,$6,$7,'pending')RETURNING*`,[req.user.userId,title,description,location,salary_min,salary_max,employment_type]);res.status(201).json(result.rows[0]);}catch(error:any){res.status(400).json({error:error.message});}});router.get('/pending',verifyToken,requireRole('admin'),async(req:Request,res:Response)=>{try{const pool=await getPool();const result=await pool.query(`SELECT*FROM job_offers WHERE status='pending'ORDER BY created_at DESC`);res.json(result.rows);}catch(error:any){res.status(400).json({error:error.message});}});router.patch('/:id/validate',verifyToken,requireRole('admin'),async(req:Request,res:Response)=>{try{const{id}=req.params;const{approved}=req.body;const pool=await getPool();const status=approved?'approved':'rejected';const result=await pool.query(`UPDATE job_offers SET status=$1,validated_by=$2,updated_at=CURRENT_TIMESTAMP WHERE id=$3RETURNING*`,[status,req.user.userId,id]);res.json(result.rows[0]);}catch(error:any){res.status(400).json({error:error.message});}});export default router;
EOF

cat > backend/src/routes/applications.ts << 'EOF'
import express,{Request,Response} from 'express';import {getPool} from '../db.js';import {verifyToken,requireRole} from '../middleware/auth.js';const router=express.Router();router.post('/',verifyToken,requireRole('candidate'),async(req:Request,res:Response)=>{try{const{offer_id}=req.body;const pool=await getPool();const result=await pool.query(`INSERT INTO applications(candidate_id,offer_id,status)VALUES($1,$2,'applied')RETURNING*`,[req.user.userId,offer_id]);res.status(201).json(result.rows[0]);}catch(error:any){res.status(400).json({error:error.message});}});router.get('/my-applications',verifyToken,requireRole('candidate'),async(req:Request,res:Response)=>{try{const pool=await getPool();const result=await pool.query(`SELECT a.*,j.title,j.description,j.location FROM applications a JOIN job_offers j ON a.offer_id=j.id WHERE a.candidate_id=$1ORDER BY a.applied_at DESC`,[req.user.userId]);res.json(result.rows);}catch(error:any){res.status(400).json({error:error.message});}});router.patch('/:id',verifyToken,requireRole('employer','admin'),async(req:Request,res:Response)=>{try{const{id}=req.params;const{status,interview_date,interview_notes}=req.body;const pool=await getPool();const result=await pool.query(`UPDATE applications SET status=$1,interview_date=$2,interview_notes=$3,updated_at=CURRENT_TIMESTAMP WHERE id=$4RETURNING*`,[status,interview_date,interview_notes,id]);res.json(result.rows[0]);}catch(error:any){res.status(400).json({error:error.message});}});export default router;
EOF

cat > backend/src/routes/users.ts << 'EOF'
import express,{Request,Response} from 'express';import {getPool} from '../db.js';import {verifyToken} from '../middleware/auth.js';const router=express.Router();router.get('/me',verifyToken,async(req:Request,res:Response)=>{try{const pool=await getPool();const result=await pool.query('SELECT id,email,name,role,profile_data FROM users WHERE id=$1',[req.user.userId]);res.json(result.rows[0]);}catch(error:any){res.status(400).json({error:error.message});}});router.patch('/me',verifyToken,async(req:Request,res:Response)=>{try{const{name,profile_data}=req.body;const pool=await getPool();const result=await pool.query(`UPDATE users SET name=COALESCE($1,name),profile_data=COALESCE($2,profile_data),updated_at=CURRENT_TIMESTAMP WHERE id=$3RETURNING id,email,name,role,profile_data`,[name,profile_data?JSON.stringify(profile_data):null,req.user.userId]);res.json(result.rows[0]);}catch(error:any){res.status(400).json({error:error.message});}});export default router;
EOF

cat > backend/src/server.ts << 'EOF'
import express from 'express';import cors from 'cors';import {config} from './config.js';import {initializeDatabase} from './db.js';import authRoutes from './routes/auth.js';import offersRoutes from './routes/offers.js';import applicationsRoutes from './routes/applications.js';import usersRoutes from './routes/users.js';const app=express();app.use(cors({origin:config.frontendUrl}));app.use(express.json());app.get('/health',(req,res)=>{res.json({status:'OK',timestamp:new Date().toISOString()});});app.use('/auth',authRoutes);app.use('/offers',offersRoutes);app.use('/applications',applicationsRoutes);app.use('/users',usersRoutes);async function start(){try{await initializeDatabase();app.listen(config.port,()=>{console.log(`🚀 Talvia Backend running on port ${config.port}`);});}catch(error){console.error('❌ Failed to start server:',error);process.exit(1);}}start();
EOF

# Frontend files
cat > frontend/tsconfig.json << 'EOF'
{"compilerOptions":{"target":"ES2020","useDefineForClassFields":true,"lib":["ES2020","DOM","DOM.Iterable"],"module":"ESNext","skipLibCheck":true,"esModuleInterop":true,"allowSyntheticDefaultImports":true,"strict":true,"noUnusedLocals":true,"noUnusedParameters":true,"noFallthroughCasesInSwitch":true,"resolveJsonModule":true,"moduleResolution":"bundler"},"include":["src"],"references":[{"path":"./tsconfig.node.json"}]}
EOF

cat > frontend/tsconfig.node.json << 'EOF'
{"compilerOptions":{"composite":true,"skipLibCheck":true,"module":"ESNext","moduleResolution":"bundler","allowSyntheticDefaultImports":true},"include":["vite.config.ts"]}
EOF

cat > frontend/.env.example << 'EOF'
VITE_API_URL=http://localhost:3000
VITE_GOOGLE_CLIENT_ID=your_google_client_id
VITE_LINKEDIN_CLIENT_ID=your_linkedin_client_id
VITE_APP_NAME=Talvia
EOF

cat > frontend/vite.config.ts << 'EOF'
import {defineConfig} from'vite';import react from'@vitejs/plugin-react';export default defineConfig({plugins:[react()],server:{port:5173,proxy:{'/api':{target:'http://localhost:3000',changeOrigin:true,rewrite:(path)=>path.replace(/^\/api/,'')}}}});
EOF

cat > frontend/index.html << 'EOF'
<!doctype html><html lang="fr"><head><meta charset="UTF-8"/><meta name="viewport"content="width=device-width,initial-scale=1.0"/><title>Talvia - Plateforme de Recrutement</title><style>*{margin:0;padding:0;box-sizing:border-box;}body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Oxygen,Ubuntu,Cantarell,sans-serif;line-height:1.6;color:#333;}button{cursor:pointer;}</style></head><body><div id="root"></div><script type="module"src="/src/main.tsx"></script></body></html>
EOF

cat > frontend/src/main.tsx << 'EOF'
import React from'react';import ReactDOM from'react-dom/client';import App from'./App.tsx';import'./index.css';ReactDOM.createRoot(document.getElementById('root')!).render(<React.StrictMode><App/></React.StrictMode>,);
EOF

cat > frontend/src/index.css << 'EOF'
:root{--primary:#3b82f6;--secondary:#1e40af;--success:#10b981;--danger:#ef4444;--warning:#f59e0b;--light:#f3f4f6;--dark:#1f2937;--border:#e5e7eb;}*{margin:0;padding:0;box-sizing:border-box;}html,body,#root{height:100%;width:100%;}body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Oxygen,Ubuntu,Cantarell,sans-serif;background-color:#fafafa;color:var(--dark);line-height:1.6;}button{cursor:pointer;padding:0.5rem 1rem;border:none;border-radius:0.375rem;font-size:1rem;transition:all 0.2s;}button.primary{background:var(--primary);color:white;}button.primary:hover{background:var(--secondary);}input,textarea,select{padding:0.5rem;border:1px solid var(--border);border-radius:0.375rem;font-size:1rem;}.container{max-width:1200px;margin:0 auto;padding:0 1rem;}.header{background:white;border-bottom:1px solid var(--border);padding:1rem 0;margin-bottom:2rem;}.nav{display:flex;justify-content:space-between;align-items:center;}.card{background:white;border:1px solid var(--border);border-radius:0.5rem;padding:1.5rem;margin-bottom:1.5rem;}.form-group{margin-bottom:1.5rem;}.form-group label{display:block;margin-bottom:0.5rem;font-weight:600;}.form-group input,.form-group textarea,.form-group select{width:100%;}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:1.5rem;}.badge{display:inline-block;padding:0.25rem 0.75rem;border-radius:9999px;font-size:0.875rem;font-weight:600;}.badge.success{background:#d1fae5;color:#065f46;}.badge.warning{background:#fef3c7;color:#92400e;}.badge.pending{background:#dbeafe;color:#0c2d6b;}
EOF

cat > frontend/src/App.css << 'EOF'
.app{min-height:100vh;display:flex;flex-direction:column;}.header{background:linear-gradient(135deg,var(--primary)0%,var(--secondary)100%);color:white;padding:1.5rem 0;box-shadow:0 2px 4px rgba(0,0,0,0.1);}.header h1{font-size:1.75rem;font-weight:700;}.nav{display:flex;justify-content:space-between;align-items:center;}.nav-links{display:flex;gap:1rem;align-items:center;}.nav-links button{background:rgba(255,255,255,0.2);color:white;border:1px solid rgba(255,255,255,0.3);padding:0.5rem 1rem;border-radius:0.375rem;transition:all 0.2s;}.nav-links button:hover{background:rgba(255,255,255,0.3);}main{flex:1;padding:2rem 0;}.loading{display:flex;justify-content:center;align-items:center;height:100vh;font-size:1.5rem;color:var(--primary);}
EOF

cat > frontend/src/types/index.ts << 'EOF'
export interface User{id:number;email:string;name:string;role:'candidate'|'employer'|'admin';profile_data?:Record<string,any>;}export interface JobOffer{id:number;title:string;description:string;location:string;salary_min?:number;salary_max?:number;employment_type:string;status:'pending'|'approved'|'rejected'|'closed';created_at:string;}export interface Application{id:number;candidate_id:number;offer_id:number;status:'applied'|'reviewed'|'interview_scheduled'|'interview_done'|'accepted'|'rejected';interview_date?:string;interview_notes?:string;applied_at:string;title?:string;description?:string;location?:string;}
EOF

cat > frontend/src/store/auth.ts << 'EOF'
import {create} from'zustand';import axios from'axios';import {User} from'../types/index.js';const API_URL=import.meta.env.VITE_API_URL||'http://localhost:3000';interface AuthStore{user:User|null;token:string|null;isLoading:boolean;login:(email:string,password:string)=>Promise<void>;register:(email:string,name:string,password:string,role:string)=>Promise<void>;logout:()=>void;setToken:(token:string,user:User)=>void;getMe:()=>Promise<void>;}export const useAuthStore=create<AuthStore>((set)=>({user:null,token:localStorage.getItem('token')||null,isLoading:false,login:async(email:string,password:string)=>{set({isLoading:true});try{const response=await axios.post(`${API_URL}/auth/login`,{email,password});const{token,user}=response.data;localStorage.setItem('token',token);axios.defaults.headers.common['Authorization']=`Bearer ${token}`;set({user,token,isLoading:false});}catch(error:any){set({isLoading:false});throw error;}},register:async(email:string,name:string,password:string,role:string)=>{set({isLoading:true});try{const response=await axios.post(`${API_URL}/auth/register`,{email,name,password,role});const{token,user}=response.data;localStorage.setItem('token',token);axios.defaults.headers.common['Authorization']=`Bearer ${token}`;set({user,token,isLoading:false});}catch(error:any){set({isLoading:false});throw error;}},logout:()=>{localStorage.removeItem('token');delete axios.defaults.headers.common['Authorization'];set({user:null,token:null});},setToken:(token:string,user:User)=>{localStorage.setItem('token',token);axios.defaults.headers.common['Authorization']=`Bearer ${token}`;set({token,user});},getMe:async()=>{try{const token=localStorage.getItem('token');if(!token)return;axios.defaults.headers.common['Authorization']=`Bearer ${token}`;const response=await axios.get(`${API_URL}/users/me`);set({user:response.data,token});}catch(error){localStorage.removeItem('token');set({user:null,token:null});}}}));
EOF

cat > frontend/src/App.tsx << 'EOF'
import{useEffect,useState} from'react';import{useAuthStore} from'./store/auth.js';import HomePage from'./pages/HomePage.js';import LoginPage from'./pages/LoginPage.js';import RegisterPage from'./pages/RegisterPage.js';import DashboardPage from'./pages/DashboardPage.js';import AdminPage from'./pages/AdminPage.js';import'./App.css';function App(){const{user,token,getMe}=useAuthStore();const[isReady,setIsReady]=useState(false);const[currentPage,setCurrentPage]=useState<string>('home');useEffect(()=>{if(token){getMe().then(()=>setIsReady(true));}else{setIsReady(true);}},[token,getMe]);if(!isReady){return<div className="loading">Chargement...</div>;}const navigate=(page:string)=>setCurrentPage(page);return<div className="app"><header className="header"><div className="container"><div className="nav"><h1 onClick={()=>navigate('home')}style={{cursor:'pointer'}}>🏢 Talvia</h1><nav className="nav-links">{!user?<><button onClick={()=>navigate('login')}className="primary">Connexion</button><button onClick={()=>navigate('register')}className="primary">Inscription</button></>:<><span>Bienvenue,{user.name}</span><button onClick={()=>navigate('dashboard')}className="primary">Tableaudebord</button>{user.role==='admin'&&<button onClick={()=>navigate('admin')}className="primary">Admin</button>}<button onClick={()=>{useAuthStore.getState().logout();navigate('home');}}className="primary">Déconnexion</button></>}</nav></div></div></header><main className="container">{!user&&currentPage==='home'&&<HomePage onNavigate={navigate}/>}{!user&&currentPage==='login'&&<LoginPage onSuccess={()=>{navigate('dashboard');}}onNavigate={navigate}/>}{!user&&currentPage==='register'&&<RegisterPage onSuccess={()=>navigate('login')}onNavigate={navigate}/>}{user&&currentPage==='dashboard'&&<DashboardPage user={user}/>}{user?.role==='admin'&&currentPage==='admin'&&<AdminPage/>}</main></div>;}export default App;
EOF

cat > frontend/src/pages/HomePage.tsx << 'EOF'
import{FC} from'react';interface HomePageProps{onNavigate:(page:string)=>void;}const HomePage:FC<HomePageProps>=({onNavigate})=><div className="home-page"><section className="hero"><h2>BienvenueSurTalvia</h2><p>PlatformedeRecrutementauLuxembourg</p><p>Trouvezvotreemploiidéalourecrutezlesmeilleurstaleants</p><divstyle={{marginTop:'2rem'}}><button className="primary"onClick={()=>onNavigate('login')}style={{marginRight:'1rem'}}>Seconnecter</button><button className="primary"onClick={()=>onNavigate('register')}>S'inscrire</button></div></section><section className="features"><h3>Fonctionnalités</h3><divclassName="grid"><div className="card"><h4>🎯Pourlesacandidats</h4><p>Créezvotreprofil,publiez votrecvtraduiraautomatiquement,etpostulez àdesoffres.</p></div><divclassName="card"><h4>🏢Pourlesemployeurs</h4><p>Publiezdeso ffres d'emploieettrouvezlescandidatslesmieuxadaptés.</p></div><div className="card"><h4>🌍Traductionaautomatique</h4><p>TouslesCVsetoffresusonttraduitsenfrançais,anglaisetluxembourgeois.</p></div></div></section></div>;export default HomePage;
EOF

cat > frontend/src/pages/LoginPage.tsx << 'EOF'
import{FC,useState} from'react';import{useAuthStore} from'../store/auth.js';interface LoginPageProps{onSuccess:()=>void;onNavigate:(page:string)=>void;}const LoginPage:FC<LoginPageProps>=({onSuccess,onNavigate})=>{const[email,setEmail]=useState('');const[password,setPassword]=useState('');const[error,setError]=useState('');const{login,isLoading}=useAuthStore();const handleSubmit=async(e:React.FormEvent)=>{e.preventDefault();try{await login(email,password);onSuccess();}catch(err:any){setError(err.response?.data?.error||'Erreurdconnexion');}};return<div className="card"style={{maxWidth:'400px',margin:'0 auto'}}><h2>Connexion</h2>{error&&<divstyle={{color:'var(--danger)',marginBottom:'1rem'}}>{error}</div>}<formOnSubmit={handleSubmit}><div className="form-group"><label>Email</label><input type="email"value={email}onChange={(e)=>setEmail(e.target.value)}required/></div><div className="form-group"><label>Motdepasse</label><input type="password"value={password}onChange={(e)=>setPassword(e.target.value)}required/></div><button type="submit"className="primary"disabled={isLoading}>{isLoading?'Connexion...':'SeConnecterr'}</button></form><pstyle={{marginTop:'1rem'}}>Pasdecompte?<ahref="#"onClick={()=>onNavigate('register')}>Inscrivez-vous</a></p></div>;};export default LoginPage;
EOF

cat > frontend/src/pages/RegisterPage.tsx << 'EOF'
import{FC,useState} from'react';import{useAuthStore} from'../store/auth.js';interface RegisterPageProps{onSuccess:()=>void;onNavigate:(page:string)=>void;}const RegisterPage:FC<RegisterPageProps>=({onSuccess,onNavigate})=>{const[email,setEmail]=useState('');const[name,setName]=useState('');const[password,setPassword]=useState('');const[role,setRole]=useState<'candidate'|'employer'>('candidate');const[error,setError]=useState('');const{register,isLoading}=useAuthStore();const handleSubmit=async(e:React.FormEvent)=>{e.preventDefault();try{await register(email,name,password,role);onSuccess();}catch(err:any){setError(err.response?.data?.error||'Erreur d\'inscription');}};return<div className="card"style={{maxWidth:'400px',margin:'0 auto'}}><h2>Inscription</h2>{error&&<divstyle={{color:'var(--danger)',marginBottom:'1rem'}}>{error}</div>}<formOnSubmit={handleSubmit}><div className="form-group"><label>Email</label><input type="email"value={email}onChange={(e)=>setEmail(e.target.value)}required/></div><div className="form-group"><label>Nom</label><input type="text"value={name}onChange={(e)=>setName(e.target.value)}required/></div><div className="form-group"><label>Motdepasse</label><input type="password"value={password}onChange={(e)=>setPassword(e.target.value)}required/></div><div className="form-group"><label>Jesuis Un:</label><select value={role}onChange={(e)=>setRole(e.target.value as any)}><option value="candidate">Candidat</option><optionvalue="employer">Employeur</option></select></div><button type="submit"className="primary"disabled={isLoading}>{isLoading?'Inscription...':'S\'inscrire'}</button></form><pstyle={{marginTop:'1rem'}}>Déjà Membre?<a href="#"onClick={()=>onNavigate('login')}>Connectez-vous</a></p></div>;};export default RegisterPage;
EOF

cat > frontend/src/pages/DashboardPage.tsx << 'EOF'
import{FC,useEffect,useState} from'react';import axios from'axios';import{User,JobOffer,Application} from'../types/index.js';interface DashboardPageProps{user:User;}const DashboardPage:FC<DashboardPageProps>=({user})=>{const[activeTab,setActiveTab]=useState<'offers'|'applications'|'profile'>('offers');const[offers,setOffers]=useState<JobOffer[]>([]);const[applications,setApplications]=useState<Application[]>([]);const[loading,setLoading]=useState(false);const API_URL=import.meta.env.VITE_API_URL||'http://localhost:3000';useEffect(()=>{loadOffers();if(user.role==='candidate'){loadApplications();}},[]);const loadOffers=async()=>{try{setLoading(true);const response=await axios.get(`${API_URL}/offers`);setOffers(response.data);}catch(error){console.error('Error loading offers:',error);}setLoading(false);};const loadApplications=async()=>{try{const response=await axios.get(`${API_URL}/applications/my-applications`);setApplications(response.data);}catch(error){console.error('Error loading applications:',error);}};const applyToOffer=async(offerId:number)=>{try{await axios.post(`${API_URL}/applications`,{offer_id:offerId});alert('Candidature envoyée!');await loadApplications();}catch(error:any){alert('Erreur:'+error.response?.data?.error);}};return<div className="dashboard"><h2>Tableaudebord</h2><divstyle={{marginBottom:'2rem',borderBottom:'1pxsolidvar(--border)'}}><button onClick={()=>setActiveTab('offers')}style={{marginRight:'1rem',fontWeight:activeTab==='offers'?'bold':'normal',borderBottom:activeTab==='offers'?'2pxsolidvar(--primary)':'none'}}>Offres d'emploi</button>{user.role==='candidate'&&<button onClick={()=>setActiveTab('applications')}style={{marginRight:'1rem',fontWeight:activeTab==='applications'?'bold':'normal',borderBottom:activeTab==='applications'?'2pxsolidvar(--primary)':'none'}}>Mescandidatures</button>}<button onClick={()=>setActiveTab('profile')}style={{fontWeight:activeTab==='profile'?'bold':'normal',borderBottom:activeTab==='profile'?'2pxsolidvar(--primary)':'none'}}>Monprofil</button></div>{activeTab==='offers'&&<div><h3>Offres d'emploidisponibles</h3>{loading?<p>Chargement...</p>:<divclassName="grid">{offers.map(offer=><div key={offer.id}className="card"><h4>{offer.title}</h4><p><strong>Lieu:</strong>{offer.location}</p><p><strong>Type:</strong>{offer.employment_type}</p>{offer.salary_min&&<p><strong>Salaire:</strong>{offer.salary_min}-{offer.salary_max}EUR</p>}<p>{offer.description.substring(0,100)}...</p>{user.role==='candidate'&&<button className="primary"onClick={()=>applyToOffer(offer.id)}>Postuler</button>}</div>))}</div>}</div>}{activeTab==='applications'&&user.role==='candidate'&&<div><h3>Mes candidatures</h3>{applications.length===0?<p>Aucune candidature pour le moment.</p>:<div className="grid">{applications.map(app=><div key={app.id}className="card"><h4>{app.title}</h4><p><strong>Statut:</strong><span className={`badge${app.status==='applied'?'pending':app.status==='accepted'?'success':'warning'}`}>{app.status}</span></p><p><strong>Datedefcandidature:</strong>{new Date(app.applied_at).toLocaleDateString('fr-FR')}</p>{app.interview_date&&<p><strong>Entretien:</strong>{new Date(app.interview_date).toLocaleDateString('fr-FR')}</p>}</div>))}</div>}</div>}{activeTab==='profile'&&<div className="card"><h3>Monprofil</h3><p><strong>Email:</strong>{user.email}</p><p><strong>Nom:</strong>{user.name}</p><p><strong>Rôle:</strong>{user.role==='candidate'?'Candidat':'Employeur'}</p></div>}</div>;};export default DashboardPage;
EOF

cat > frontend/src/pages/AdminPage.tsx << 'EOF'
import{FC,useEffect,useState} from'react';import axios from'axios';import{JobOffer} from'../types/index.js';const AdminPage:FC=()=>{const[pendingOffers,setPendingOffers]=useState<JobOffer[]>([]);const[loading,setLoading]=useState(false);const API_URL=import.meta.env.VITE_API_URL||'http://localhost:3000';useEffect(()=>{loadPendingOffers();},[]);const loadPendingOffers=async()=>{try{setLoading(true);const response=await axios.get(`${API_URL}/offers/pending`);setPendingOffers(response.data);}catch(error){console.error('Error loading pending offers:',error);}setLoading(false);};const validateOffer=async(offerId:number,approved:boolean)=>{try{await axios.patch(`${API_URL}/offers/${offerId}/validate`,{approved});alert(approved?'Offre validée!':'Offre rejetée.');await loadPendingOffers();}catch(error:any){alert('Erreur:'+error.response?.data?.error);}};return<div><h2>Panel d'administration</h2><h3>Offres en attente de validation</h3>{loading?<p>Chargement...</p>:pendingOffers.length===0?<p>Aucune offre en attente.</p>:<div className="grid">{pendingOffers.map(offer=><div key={offer.id}className="card"><h4>{offer.title}</h4><p><strong>Entreprise:</strong>ID{offer.id}</p><p><strong>Lieu:</strong>{offer.location}</p><p>{offer.description.substring(0,150)}...</p><div style={{marginTop:'1rem'}}><button className="primary"onClick={()=>validateOffer(offer.id,true)}style={{marginRight:'0.5rem'}}>✓ Valider</button><button className="primary"onClick={()=>validateOffer(offer.id,false)}style={{background:'var(--danger)'}}>✗ Rejeter</button></div></div>))}</div>}</div>;};export default AdminPage;
EOF

cat > frontend/Dockerfile << 'EOF'
FROM node:18-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build
FROM node:18-alpine
WORKDIR /app
RUN npm install -g serve
COPY --from=builder /app/dist ./dist
EXPOSE 5173
CMD ["serve", "-s", "dist", "-l", "5173"]
EOF

cat > docker-compose.yml << 'EOF'
version: '3.8'
services:
 postgres:
 image: postgres:15
 environment:
 POSTGRES_DB: talvia
 POSTGRES_USER: talvia
 POSTGRES_PASSWORD: talvia_secure_password
 volumes:
 - postgres_data:/var/lib/postgresql/data
 ports:
 - "5432:5432"
 healthcheck:
 test: ["CMD-SHELL", "pg_isready -U talvia"]
 interval: 10s
 timeout: 5s
 retries: 5
 backend:
 build: ./backend
 environment:
 NODE_ENV: development
 PORT: 3000
 DATABASE_URL: postgresql://talvia:talvia_secure_password@postgres:5432/talvia
 JWT_SECRET: dev_secret_key_change_in_production
 LIBRETRANSLATE_URL: https://libretranslate.de
 FRONTEND_URL: http://localhost:5173
 ports:
 - "3000:3000"
 depends_on:
 postgres:
 condition: service_healthy
 frontend:
 build: ./frontend
 environment:
 VITE_API_URL: http://localhost:3000
 ports:
 - "5173:5173"
 depends_on:
 - backend
volumes:
 postgres_data:
EOF

echo "✅ All files generated successfully!"
