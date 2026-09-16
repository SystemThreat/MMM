"""Address validation and native bridge contract regression checks; no mining."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'App.swift').read_text()
validator='import Foundation\n'+source[source.index('func validAddress('):source.index('@main')]
# Real witness-v3 testnet address and independently encode a matching mainnet script.
charset='qpzry9x8gf2tvdw0s3jn54khce6mua7l'
test='txa1r4dygyzk5mw0cv7ujekjkcql3wz9cgrwcc327h57kcva579644vpqhk4h48'
def encode(hrp,data):
    chk=1
    for v in [ord(c)>>5 for c in hrp]+[0]+[ord(c)&31 for c in hrp]+data+[0]*6:
        top=chk>>25;chk=((chk&0x1ffffff)<<5)^v
        for i,g in enumerate([0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3]):
            if (top>>i)&1:chk^=g
    chk^=0x2bc830a3
    return hrp+'1'+''.join(charset[v] for v in data+[(chk>>(5*(5-i)))&31 for i in range(6)])
data=[charset.index(c) for c in test[4:-6]]
main=encode('xpa',data)
cases=[(test,'txa',True),(main,'xpa',True),(test,'xpa',False),(main,'txa',False),(test[:-1]+'q','txa',False),(test.upper(),'txa',True),('T'+test[1:],'txa',False),(encode('txa',[2]+data[1:]),'txa',False),(encode('txa',data[:-1]+[data[-1]|1]),'txa',False)]
checks='\n'.join(f'assert(validAddress("{a}", hrp:"{h}") == {str(ok).lower()})' for a,h,ok in cases)
(root/'build').mkdir(exist_ok=True)
swift=root/'build/AddressTests.swift';swift.write_text(validator+'\n'+checks+'\n'+f'''
var config = ["network":"testnet","address":"{test}","host":"127.0.0.1","port":"3335","worker":"test"]
assert(startupSettingsComplete(config))
config["network"]="mainnet"; assert(!startupSettingsComplete(config))
config["address"]="{main}"; assert(startupSettingsComplete(config))
config["port"]=""; assert(!startupSettingsComplete(config))
config["port"]="3335"; config["worker"]=""; assert(!startupSettingsComplete(config))
assert(!startupSettingsComplete([:]))
'''+ '\nprint("9 address validation cases passed")\n')
subprocess.run(['swiftc','-module-cache-path',str(root/'build/module-cache'),str(swift),'-o',str(root/'build/address-tests')],check=True)
subprocess.run([str(root/'build/address-tests')],check=True)
subprocess.run(['node','--check',str(root/'app.js')],check=True)
engine=(root/'Engine/main.swift').read_text()
assert 'cfg.password = readLine()' in engine
assert '[credentials redacted]' in engine
assert 'jsonString(config.password)' in engine
assert 'submittedPassword = b["password"]' in source
assert 'register(defaults:["autoStartMining":true])' in source
assert 'UserDefaults.standard.set(enabled,forKey:"autoStartMining")' in source
print('Password pipe, JSON escaping, log redaction, and JS syntax passed')
