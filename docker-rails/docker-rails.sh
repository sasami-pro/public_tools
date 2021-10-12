#!/bin/bash

# このスクリプトは以下の動作を行います
# 1.カレントディレクトリのdocker-rails.sh and README.md以外のファイルを削除
# 2.Rails用entrypoint.sh,Gemfile,Dockerfileの作成
# 3.MySQL用のlocale.gen,my.cnf,init_mysql.sql,Dockerfileを作成
# 4.docker-compose.ymlの作成
# 5.DockerfileのビルドおよびRailsのDB接続設定


echo "------------------------------------------------------------------------------"
echo "docker-rails.sh and README.md以外のファイルを削除"
echo "------------------------------------------------------------------------------"
ls | grep -v -E 'docker-rails.sh|README.md' | xargs sudo rm -rf

function usage {
  cat <<'EOM'
Usage: /bin/bash init.sh [OPTIONS] [VALUE]
Options:
  -h            Display help
  -n  [VALUE]   Give a project's name[required]
  -p  [VALUE]   Define a mysql root password[required]
EOM
  exit 1
}

while getopts ":p:n:h" optKey; do
  case "$optKey" in
    n)
      project_name=$OPTARG
      ;;
    p)
      root_password=$OPTARG
      ;;
    '-h'|'--help'|* )
      usage
      ;;
  esac
done

if [ -z $project_name ] || [ -z $root_password ]; then
  echo -e "you must define project name and mysql root password.\n"
  usage
  exit 1
fi

set -ex
echo -e "start!!\n"

app_root="/usr/src/$project_name"

echo "------------------------------------------------------------------------------"
echo "Rails環境用entrypoint.sh,Gemfile,Dockerfileの作成"
echo "------------------------------------------------------------------------------"
cat <<'EOF' > entrypoint.sh
#!/bin/bash

# Railsの仕様でDocker上だと余分なserver.pidが残り続けてエラーになるため、
# Railsを実行するたびに削除する
rm -f /$project_name/tmp/pids/server.pid

# デフォルトUID&GIDを設定
USER_ID=${LOCAL_UID:-1000}
GROUP_ID=${LOCAL_GID:-1000}

# Railsを実行するユーザーを作成
groupadd -r --gid $GROUP_ID rails
useradd -u $USER_ID -o -m -g $GROUP_ID  -G sudo rails

export HOME=/home/rails

# ユーザーrailsに/usr/srcへの権限を付与
chown -R rails:rails /usr/src

# Railsはsudo以上の権限でないとインストールできないため、
# 作成したユーザーrailsにsudo権限の付与
echo "rails ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# 作成したユーザーrailsでDockerを実行
exec /usr/sbin/gosu rails "$@"
EOF

cat <<EOF > Gemfile
source 'https://rubygems.org'
gem 'rails', "~>6.1.4"
EOF

mkdir $project_name
mv Gemfile ./$project_name
touch ./$project_name/Gemfile.lock

cat <<EOF > Dockerfile
FROM ruby:3.0.2

ENV LANG C.UTF-8
ENV TZ Asia/Tokyo
WORKDIR $app_root

# gosuなど必要なライブラリのインストール
RUN set -ex && \
    apt-get update -qq && \
    apt-get install -y sudo && \
    : "Install node.js" && \
    curl -sL https://deb.nodesource.com/setup_14.x | sudo -E bash - && \
    apt-get update -qq && \
    apt-get install -y nodejs && \
    : "Install yarn" && \
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add - && \
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list && \
    apt-get update -qq && \
    apt-get install -y yarn && \
    apt-get -y install gosu

# ローカルのGemfileおよびGemfile.lockをDockerコンテナにコピー
COPY ./$project_name/Gemfile $app_root/Gemfile
COPY ./$project_name/Gemfile.lock $app_root/Gemfile.lock

# 上記のGemfileを元にDockerコンテナへRailsをインストール
RUN bundle install

# ローカルのentrypoint.shをDockerコンテナへコピーし、
# Dockerコンテナ上で実行できるように権限を付与。
# DcokerコンテナのENTRYPOINTで実行するように設定。
COPY ./rails/entrypoint.sh /usr/bin/entrypoint.sh
RUN chmod +x /usr/bin/entrypoint.sh
ENTRYPOINT ["/usr/bin/entrypoint.sh"]
EXPOSE 3000

CMD ["rails", "server", "-b", "0.0.0.0"]
EOF

mkdir rails
mv entrypoint.sh ./rails

mv Dockerfile ./rails
touch ./rails/.dockerignore


echo "------------------------------------------------------------------------------"
echo "MySQL用のlocale.gen,my.cnf,init_mysql.sql,Dockerfileを作成"
echo "------------------------------------------------------------------------------"
cat <<EOF > locale.gen
ja_JP.UTF-8 UTF-8
EOF

mkdir ./mysql
mkdir ./mysql/data
mkdir ./mysql/mysql-confd
mv locale.gen ./mysql/mysql-confd
touch ./mysql/.dockerignore

cat <<EOF > my.cnf
[mysqld]
default_authentication_plugin=mysql_native_password
character-set-server=utf8mb4
collation-server=utf8mb4_general_ci

[client]
default-character-set=utf8mb4
EOF

mv my.cnf ./mysql/mysql-confd

cat <<EOF > init_mysql.sql
# ユーザーが存在しない場合のみ、新規ユーザーを作成するsql
SET @sql_found='SELECT 1 INTO @x';
SET @sql_fresh='GRANT ALL ON *.* TO "$project_name"@''%''';
SELECT COUNT(1) INTO @found_count FROM mysql.user WHERE user='"$project_name"' AND host='%';
SET @sql=IF(@found_count=1,@sql_found,@sql_fresh);
PREPARE s FROM @sql;
EXECUTE s;
DEALLOCATE PREPARE s;
EOF

mkdir ./mysql/docker-entrypoint-initdb.d
mv init_mysql.sql ./mysql/docker-entrypoint-initdb.d

cat <<EOF > Dockerfile
FROM mysql:8.0

RUN groupmod -g 1000 mysql && usermod -u 1000 -g 1000 mysql
RUN echo "rails ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

COPY ./mysql/mysql-confd/locale.gen /etc/locale.gen

RUN sed -i 's@archive.ubuntu.com@ftp.jaist.ac.jp/pub/Linux@g' /etc/apt/sources.list
RUN set -ex && \
    apt-get update -qq && \
    : "Install locales" && \
    apt-get install -y --no-install-recommends locales && \
    : "Cleaning..." && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    locale-gen ja_JP.UTF-8
ENV LC_ALL ja_JP.UTF-8
COPY ./mysql/mysql-confd/my.cnf /etc/mysql/conf.d/my.cnf
COPY ./mysql/docker-entrypoint-initdb.d/init_mysql.sql /docker-entrypoint-initdb.d/init_mysql.sql

EOF

mv Dockerfile ./mysql

echo "------------------------------------------------------------------------------"
echo "docker-compose.ymlを作成"
echo "------------------------------------------------------------------------------"
cat <<EOF > docker-compose.yml
version: '3.9'
services:
  db:
    build:
      context: .
      dockerfile: ./mysql/Dockerfile
    container_name: rails_mysql
    user: "1000:1000"
    ports:
      - "3306:3306"
    environment:
      MYSQL_USER: "$project_name"
      MYSQL_PASSWORD: "$project_name"
      MYSQL_ROOT_PASSWORD: "$root_password"
      MYSQL_HOST: "db"
      TZ: "Asia/Tokyo"
    volumes:
      - ./mysql/data:/var/lib/mysql
      - ./mysql/mysql-confd/my.cnf:/etc/mysql/conf.d/my.cnf
      - ./mysql/docker-entrypoint-initdb.d:/docker-entrypoint-initdb.d
  web:
    build:
      context: .
      dockerfile: ./rails/Dockerfile
    command: bash -c "rm -f tmp/pids/server.pid && bundle exec rails s -p 3000 -b '0.0.0.0'"
    container_name: rails_web
    environment:
      MYSQL_USER: "$project_name"
      MYSQL_PASSWORD: "$project_name"
      MYSQL_ROOT_PASSWORD: "$root_password"
      MYSQL_HOST: "db"
      TZ: "Asia/Tokyo"
    volumes:
      - ./$project_name:/usr/src/$project_name
    ports:
      - "3000:3000"
    stdin_open: true
    tty: true
    depends_on:
      - db
EOF


echo "------------------------------------------------------------------------------"
echo "DockerfileのビルドおよびRailsのDB接続設定"
echo "------------------------------------------------------------------------------"
cd $project_name

docker-compose run --no-deps web rails new . --force --database=mysql

docker-compose build --no-cache

docker-compose run web /bin/sh -c "sed -ie '0,/password:/ s/password:/password: <%= ENV.fetch('\"'MYSQL_PASSWORD'\"') { '\"'$root_password'\"' } %>/g' ./config/database.yml"
docker-compose run web /bin/sh -c "sed -ie 's/host: localhost/host: <%= ENV.fetch('\"'MYSQL_HOST'\"') { '\"'db'\"' } %>/g' ./config/database.yml"
docker-compose run web /bin/sh -c "sed -ie 's/username: root/username: <%= ENV.fetch('\"'MYSQL_USER'\"') { '\"'$project_name'\"' } %>/g' ./config/database.yml"
docker-compose run web /bin/sh -c "sed -ie 's/username: $project_name/username: <%= ENV.fetch('\"'MYSQL_USER'\"') { '\"'$project_name'\"' } %>/g' ./config/database.yml"

docker-compose run web rails db:create

docker-compose build --no-cache

docker-compose up -d