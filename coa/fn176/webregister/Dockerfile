# CoA 注册站（玩家账号注册页），容器化运行在 fn176。
# 源码来自旧服 192.168.1.89 的 C:\COA\CoA-Repack\WebRegister\register_server.py，
# 仅两处改动：Settings 新增可选 mysqlHost/appUser（默认仍是 127.0.0.1/acore），
# 以及 realm_has_character 里的 characters 表加库名前缀。
FROM python:3.12-slim

RUN pip install --no-cache-dir -i https://mirrors.aliyun.com/pypi/simple/ pymysql pillow

WORKDIR /app
COPY context/WebRegister/register_server.py /app/WebRegister/register_server.py
COPY context/WebRegister/index.html       /app/WebRegister/index.html
COPY context/Settings                      /app/Settings

EXPOSE 8090
ENTRYPOINT ["python", "/app/WebRegister/register_server.py"]
CMD ["--host", "0.0.0.0", "--port", "8090"]
