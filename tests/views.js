// Exercise the actual tab/pagination/theme functions without a browser or GPU.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(require('node:path').join(__dirname,'../app.js'),'utf8');
function func(name){const start=source.indexOf('function '+name+'(');let level=0,begin=source.indexOf('{',start);for(let i=begin;i<source.length;i++){if(source[i]==='{')level++;if(source[i]==='}'&&--level===0)return source.slice(start,i+1)}throw Error(name)}
const elements={};function get(id){return elements[id]??=( {hidden:false,attrs:{},classList:{toggle(){}},setAttribute(k,v){this.attrs[k]=v},querySelector(){return {clientHeight:300}}})}
let renders=0,stored;const context=vm.createContext({$:get,blockPage:99,minerPage:0,renderBlocks(){renders++},renderMiners(){renders++},renderLog(){renders++},document:{documentElement:{dataset:{}}},getComputedStyle(){return {getPropertyValue(key){return key==='--table-row-height'?'72px':'42px'}}},localStorage:{setItem(k,v){stored=v}}});
for(const name of ['selectTab','pageInfo','applyTheme'])vm.runInContext(func(name),context);
context.selectTab('miners');assert.equal(get('view-miners').hidden,false);assert.equal(get('view-dashboard').hidden,true);assert.equal(get('tab-miners').attrs['aria-selected'],'true');assert.equal(get('tab-dashboard').tabIndex,-1);
context.selectTab('setup');assert.equal(get('view-miners').hidden,true);assert.equal(get('view-setup').hidden,false);
context.selectTab('invalid');assert.equal(get('view-dashboard').hidden,false);
let p=context.pageInfo('blocks',8);assert.equal(p.count,3);assert.equal(p.start,6);assert.equal(get('blocksNext').disabled,true);assert.equal(get('blocksPrev').disabled,false);
p=context.pageInfo('miners',0);assert.equal(p.start,0);assert.equal(get('minersPrev').disabled,true);assert.equal(get('minersNext').disabled,true);
get('blocks').querySelector=()=>({clientHeight:50});p=context.pageInfo('blocks',8);assert.equal(p.count,1);
context.applyTheme(true);assert.equal(stored,'dark');assert.equal(get('themeToggle').attrs['aria-checked'],'true');context.applyTheme(false);assert.equal(stored,'light');assert.equal(get('themeLabel').textContent,'LIGHT');
console.log('Tab selection, hidden panels, pagination bounds, short windows, and theme persistence passed');
