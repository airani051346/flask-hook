how to install:

```bash
curl kjbkjb| sudo bash 
```

test localy:  
cpadmin@awx1:~$ curl -X POST http://127.0.0.1/webhook        -H 'Content-Type: application/json'        -H 'X-Webhook-Token: mysecrettoken123'        -d '{"event":"test","value":123}'
