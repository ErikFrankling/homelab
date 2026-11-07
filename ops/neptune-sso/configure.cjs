// Run in the Planet9 container. The client secret arrives on stdin; no secrets
// are logged. Back up planet9_settings.config before applying (docs/sso.md).
const {Client}=require('pg');
const crypto=require('crypto');
const fs=require('fs');
const c=new Client({host:process.env.DB_PSQL_HOST,port:process.env.DB_PSQL_PORT,database:process.env.DB_PSQL_DBNAME,user:process.env.DB_PSQL_USER,password:process.env.DB_PSQL_PASSWORD});
(async()=>{
 const secret=fs.readFileSync(0,'utf8').trim();
 if(secret.length<32) throw new Error('Missing client secret');
 const schema=process.env.DB_PSQL_SCHEMA;
 if(!/^[a-zA-Z0-9_]+$/.test(schema)) throw new Error('Invalid schema');
 await c.connect(); await c.query('BEGIN');
 const rows=(await c.query(`SELECT id,config FROM "${schema}".planet9_settings FOR UPDATE`)).rows;
 if(rows.length!==1) throw new Error('Expected one settings record');
 const {id,config}=rows[0];
 const key=crypto.createHash('sha256').update(config.tokenSecret).digest();
 const cipher=crypto.createCipheriv('aes-256-ctr',key,Buffer.alloc(16,key));
 const clientSecret=Buffer.concat([cipher.update(secret),cipher.final()]).toString('hex');
 const previous=config.idp.find(x=>x.path==='homelab');
 const provider={id:previous?.id||crypto.randomUUID(),name:'Homelab',type:'openid-connect',path:'homelab',active:true,show:true,
 identityMetadata:'https://auth.erikfrankling.duckdns.org/application/o/neptune/.well-known/openid-configuration',
 clientID:'homelab-neptune',clientSecret,scope:'openid profile email',tokenAuth:'basic',prompt:'none',
 redirectUrl:'https://planet9-test.erikfrankling.duckdns.org/user/logon/openid-connect/homelab/callback',
 loginRedirectUrl:'/cockpit.html',roleAssignment:[],departmentAssignment:[],assignFirstLogin:true,
 claimsMap:[{id:crypto.randomUUID(),userField:'username',claim:'preferred_username'}]};
 // Link the existing owner instead of creating a second account. Keep its ID,
 // password hash, admin flag, data and role relations; only change IDP metadata.
 const owners=(await c.query(`SELECT id,admin,"idpSource" FROM "${schema}".users WHERE username=$1 FOR UPDATE`,['admin'])).rows;
 if(owners.length!==1 || !owners[0].admin || !['local','openid-connect'].includes(owners[0].idpSource)) throw new Error('Unexpected existing owner');
 await c.query(`UPDATE "${schema}".users SET "idpSource"=$1,"idpSourceId"=$2,"idpSourceKey"=$3 WHERE id=$4`,['openid-connect',provider.id,'homelab',owners[0].id]);
 config.idp=[...config.idp.filter(x=>x.path!=='homelab'),provider];
 config.defaultLoginUrl='/user/logon/openid-connect/homelab';
 // Recovery/API authentication stays available; the browser enters OIDC directly.
 await c.query(`UPDATE "${schema}".planet9_settings SET config=$1 WHERE id=$2`,[config,id]);
 await c.query('COMMIT'); await c.end(); console.log('Neptune native OIDC and automatic entry configured');
})().catch(e=>{console.error(e.message);process.exit(1)});
