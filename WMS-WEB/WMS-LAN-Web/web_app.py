# -*- coding: utf-8 -*-
"""WMS LAN web wrapper; reuses wms_integrated.py business functions."""
import time,secrets,threading,importlib.util,re
from pathlib import Path
from datetime import datetime
from decimal import Decimal
import requests
from fastapi import FastAPI,HTTPException,Request,Depends
from fastapi.responses import HTMLResponse
from starlette.middleware.sessions import SessionMiddleware
from pydantic import BaseModel,Field
ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('wms_business',ROOT/'wms_integrated.py'); wms=importlib.util.module_from_spec(spec); spec.loader.exec_module(wms)
app=FastAPI(title='WMS 局域网出库助手',docs_url=None,redoc_url=None,openapi_url=None)
secret_file=ROOT/'.web_session_secret'
if not secret_file.exists(): secret_file.write_text(secrets.token_urlsafe(48),encoding='utf-8')
app.add_middleware(SessionMiddleware,secret_key=secret_file.read_text(encoding='utf-8').strip(),same_site='strict',https_only=False,max_age=28800)
LOCK=threading.RLock(); DRAFTS={}; PDA={}; JOBS=[]; TASKS=[]; MONITOR={'state':'初始化中','last_check':None,'error':None}
S=requests.Session(); S.headers.update({'Accept':'application/json, text/plain, */*'})
class SearchBody(BaseModel): keyword:str=Field(min_length=1,max_length=100)
class DraftLine(BaseModel): keyword:str=Field(min_length=1,max_length=100); index:int=Field(ge=0,le=9); quantity:str=Field(min_length=1,max_length=30); unit:str=Field(min_length=1,max_length=12)
class DraftBody(BaseModel): items:list[DraftLine]=Field(min_length=1,max_length=20)
class ConfirmBody(BaseModel): confirm:str=Field(max_length=20)
class TrayBody(BaseModel): tray:str=Field(min_length=1,max_length=30)
class PDAConfirmBody(BaseModel): preview_id:str; quantities:dict[str,str]; confirm:str=Field(max_length=20)
def sid(r):
 if not r.session.get('sid'): r.session['sid']=secrets.token_urlsafe(24)
 return r.session['sid']
def auth(r:Request):
 # 局域网免口令模式：仅依赖浏览器会话区分草稿所有者，不做登录认证。
 return sid(r)
def clean(m): return {k:str(m.get(k,'')) for k in ('MaterialId','MaterialName','MaterialNo','Specification','Unit','IsDel')}
def fmt(v): return wms.fmt_decimal(Decimal(str(v)))
def snapshot_worker():
 while True:
  try:
   if not wms.WMS_PASSWORD: MONITOR.update(state='未配置 WMS 密码',error='请在本机 wms_config.json 配置账号密码'); time.sleep(10); continue
   s=requests.Session()
   if not wms.monitor_login(s,wms.WMS_USERNAME,wms.WMS_PASSWORD): raise RuntimeError('只读任务查询登录验证失败')
   rows=wms.monitor_fetch_recent_tasks(s,set(),initial=True); rows=sorted(rows,key=lambda x:str(x.get('CreateDate','')),reverse=True)[:100]
   view=[{'TaskCode':str(x.get('TaskCode','')),'TaskMainId':str(x.get('TaskMainId','')),'TaskType':str(x.get('TaskType','')),'Status':str(x.get('Status','')),'OutStation':str(x.get('OutStation','')),'TrayCode':str(x.get('TrayCode','')),'CreateDate':wms.monitor_format_date(x.get('CreateDate'))} for x in rows]
   with LOCK: TASKS[:]=view
   MONITOR.update(state='监控查询正常',last_check=datetime.now().isoformat(timespec='seconds'),error=None)
  except Exception as e: MONITOR.update(state='监控查询异常',last_check=datetime.now().isoformat(timespec='seconds'),error=str(e)[:250])
  time.sleep(10)
@app.on_event('startup')
def startup():
 if not wms.WMS_PASSWORD: MONITOR.update(state='未配置 WMS 密码',error='请在 wms_config.json 配置账号密码'); return
 try:
  if wms.login(S,wms.WMS_USERNAME,wms.WMS_PASSWORD) and wms.verify_session(S): MONITOR.update(state='WMS 会话正常',error=None)
  else: MONITOR.update(state='WMS 登录失败',error='请检查 WMS 账号密码和网络')
 except Exception as e: MONITOR.update(state='WMS 连接异常',error=str(e)[:250])
 threading.Thread(target=wms.background_monitor_worker,args=(wms.WMS_USERNAME,wms.WMS_PASSWORD),daemon=True,name='original-wms-monitor').start()
 threading.Thread(target=snapshot_worker,daemon=True,name='web-task-snapshot').start()
@app.get('/',response_class=HTMLResponse)
def index(): return HTML
@app.get('/api/status')
def status(user=Depends(auth)): return {'monitor':MONITOR,'tasks':TASKS[:100],'jobs':JOBS[-30:]}
@app.post('/api/material-search')
def material_search(b:SearchBody,user=Depends(auth)):
 try: return {'items':[{'index':i,'score':round(score,3),**clean(m)} for i,(score,m) in enumerate(wms.search_materials(S,b.keyword)[:10])]}
 except Exception as e: raise HTTPException(502,'物料查询失败：'+str(e)[:200])
@app.post('/api/stockout/draft')
def draft(b:DraftBody,user=Depends(auth)):
 items=[]
 try:
  for line in b.items:
   ranked=wms.search_materials(S,line.keyword)[:10]
   if line.index>=len(ranked): raise ValueError(f'物料“{line.keyword}”候选项已变化，请重新搜索')
   m=ranked[line.index][1]; qty=Decimal(line.quantity)
   if not qty.is_finite() or qty<=0: raise ValueError('数量必须为大于 0 的有效数字')
   weight=wms.calculate_plan_weight({'query_name':line.keyword,'quantity':qty,'input_unit':line.unit.lower()},m)
   items.append({'query_name':line.keyword,'quantity':qty,'input_unit':line.unit.lower(),'material':m,'plan_weight_kg':weight})
 except Exception as e: raise HTTPException(400,str(e)[:250])
 did=secrets.token_urlsafe(18)
 with LOCK: DRAFTS[did]={'owner':user,'items':items,'state':'待确认'}
 return {'draft_id':did,'items':[{'query_name':i['query_name'],'quantity':fmt(i['quantity']),'input_unit':i['input_unit'],'material':clean(i['material']),'plan_weight_kg':fmt(i['plan_weight_kg'])} for i in items],'stockout_type':wms.STOCKOUT_TYPE_NAME,'out_station':wms.OUT_STATION_NAME}
@app.post('/api/stockout/confirm/{did}')
def stockout_confirm(did:str,b:ConfirmBody,user=Depends(auth)):
 if b.confirm!='CONFIRM': raise HTTPException(400,'请输入 CONFIRM 确认真实出库写操作')
 with LOCK:
  d=DRAFTS.get(did)
  if not d or d['owner']!=user: raise HTTPException(404,'草稿不存在')
  if d['state']!='待确认': raise HTTPException(409,'草稿已提交或正在处理，禁止重复提交')
  d['state']='执行中'
 job={'id':secrets.token_urlsafe(8),'type':'生产领料出库','state':'执行中','message':'执行中；请勿重复提交','time':datetime.now().isoformat(timespec='seconds')}; JOBS.append(job)
 try:
  stockout=wms.create_stockout(S); oid=str(stockout.get('StockOutId'))
  if not oid or oid=='None': raise RuntimeError('创建后未取得 StockOutId，请人工核查 WMS')
  for item in d['items']: wms.add_stockout_detail(S,oid,item)
  row=wms.find_stockout_by_id(S,oid)
  if not row: raise RuntimeError('无法查询新单据状态；停止后续操作，请人工核查')
  state=wms.get_status(row)
  if state==wms.STATUS_PENDING_AUDIT:
   try: wms.audit_stockout_once(S,oid)
   except Exception as e: print('[网页] 自动审核未确认：',e)
   row=wms.wait_for_stockout_status(S,oid,{wms.STATUS_AUDITED,wms.STATUS_ALLOTTED},attempts=6,interval=2)
   if not row: raise RuntimeError(f"出库单 {stockout.get('StockOutNo','')} 已创建但审核未确认。请在 WMS 人工核查/审核；网页不会自动分配")
   state=wms.get_status(row)
  if state==wms.STATUS_ALLOTTED: msg='单据已处于分配后状态，未重复分配'
  elif state==wms.STATUS_AUDITED: wms.allot_stockout(S,oid); msg='已提交分配流程，请在 WMS 核实最终状态'
  else: raise RuntimeError(f'单据状态 {state} 不符合预期；停止后续写操作')
  job.update(state='已执行（需核验）',message=f"单号：{stockout.get('StockOutNo','-')}；ID：{oid}；{msg}"); return {'ok':True,'job':job}
 except Exception as e:
  job.update(state='需人工核查',message=str(e)[:350]); raise HTTPException(409,'流程停止，可能已有部分业务数据写入。请先到 WMS 核对，勿直接重试。详情：'+str(e)[:250])
 finally:
  with LOCK: d['state']='已提交'
@app.post('/api/pda/query')
def pda_query(b:TrayBody,user=Depends(auth)):
 tray=b.tray.strip().upper()
 if not re.fullmatch(r'[A-Za-z]\d{5}',tray): raise HTTPException(400,'托盘号格式应类似 A00555')
 try: tasks=wms.pda_query_tasks(tray)
 except Exception as e: raise HTTPException(502,'PDA 查询失败：'+str(e)[:220])
 if not tasks: raise HTTPException(404,'没有查询到该托盘的出库任务')
 items=[]; seen=set()
 try:
  for t in tasks:
   did=str(t.get('TaskDetailId') or '')
   if not did.isdigit() or did in seen: raise ValueError('TaskDetailId 无效或重复')
   seen.add(did); q=Decimal(str(t['Qty']))
   if not q.is_finite() or q<=0: raise ValueError('计划数量无效')
   items.append({'TaskDetailId':did,'MaterialName':str(t.get('MaterialName','')),'MaterialNo':str(t.get('MaterialNo','')),'Specification':str(t.get('Specification','')),'Status':str(t.get('Status','')),'plan':fmt(q)})
 except Exception as e: raise HTTPException(502,'任务数据格式错误：'+str(e))
 pid=secrets.token_urlsafe(18)
 with LOCK: PDA[pid]={'owner':user,'tray':tray,'items':items,'state':'待确认'}
 return {'preview_id':pid,'tray':tray,'items':items}
@app.post('/api/pda/confirm')
def pda_confirm(b:PDAConfirmBody,user=Depends(auth)):
 if b.confirm!='CONFIRM': raise HTTPException(400,'真实出库确认必须输入 CONFIRM')
 with LOCK:
  p=PDA.get(b.preview_id)
  if not p or p['owner']!=user: raise HTTPException(404,'托盘预览不存在')
  if p['state']!='待确认': raise HTTPException(409,'该预览已提交，禁止重复提交')
  p['state']='提交中'
 try:
  parts=[]; plan_total=Decimal(0); actual_total=Decimal(0)
  for item in p['items']:
   key=item['TaskDetailId']
   if key not in b.quantities: raise ValueError('缺少物料实际数量')
   actual=Decimal(b.quantities[key]); plan=Decimal(item['plan'])
   if not actual.is_finite() or actual<=0 or actual>plan or actual!=actual.to_integral_value(): raise ValueError(f"{item['MaterialName']} 实际数量必须为正整数且不超过计划量")
   parts.append(key+'|'+fmt(actual)+';'); plan_total+=plan; actual_total+=actual
  # 与原脚本相同序列化格式；请求只发送一次，不自动重试。
  result=wms.pda_request('OutTaskConfirm',p['tray']+','+''.join(parts)); ok=wms.pda_check_success(result)
  job={'id':secrets.token_urlsafe(8),'type':'PDA实际出库','state':'服务器返回成功' if ok else '需人工核查','message':f"托盘 {p['tray']}；计划 {fmt(plan_total)}；实际 {fmt(actual_total)}；剩余 {fmt(plan_total-actual_total)}；响应 {str(result)[:150]}",'time':datetime.now().isoformat(timespec='seconds')}; JOBS.append(job)
  return {'ok':ok,'job':job,'warning':'无论返回成功与否，请在 WMS 页面核对库存与任务状态；不要重复提交。'}
 except Exception as e:
  JOBS.append({'id':secrets.token_urlsafe(8),'type':'PDA实际出库','state':'需人工核查','message':str(e)[:250],'time':datetime.now().isoformat(timespec='seconds')})
  raise HTTPException(409,'请求异常或数据无效。若已发送请求，请先核对 WMS 状态，勿重复提交。详情：'+str(e)[:180])
 finally:
  with LOCK: p['state']='已提交'
HTML=(ROOT/'index.html').read_text(encoding='utf-8')
