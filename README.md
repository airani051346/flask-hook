how to install:
copy the URL below and add domain(public dns name) and email address as required<br> 
<img width="1061" height="136" alt="image" src="https://github.com/user-attachments/assets/a2bb374e-23ee-4300-a550-bdcfb6b22094" />

you can get your publicly avilable dns name from azure for example here:
<img width="1769" height="711" alt="image" src="https://github.com/user-attachments/assets/29980833-59ff-4249-b543-26883dda3fb2" />


```bash
curl -sSL https://raw.githubusercontent.com/airani051346/flask-hook/refs/heads/main/simple-flask-app.sh | sudo bash -s -- --domain <mydomain.com> --email=<admin-mailaddr> --secret=<mysecrettoken123>
```
after installation please run following command to test localy:

```bash
curl -X POST http://127.0.0.1/webhook \
     -H 'Content-Type: application/json' \
     -H 'X-Webhook-Token: <mysecrettoken123>'
     -d '{"event":"test","value":123}'
```
your response should look like:

```bash
{"message":"Webhook received successfully","received_data":{"event":"test","value":123},"status":"success"}
```
