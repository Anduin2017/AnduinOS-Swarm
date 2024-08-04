sudo docker stack rm $(sudo docker stack ls --format '{{.Name}}')
sleep 1
sudo docker stop $(sudo docker ps -aq)
sleep 1
sudo docker kill $(sudo docker ps -aq)
sleep 1
sudo docker rm $(sudo docker ps -aq)
sleep 1
sudo docker volume rm $(sudo docker volume ls -q) -f
sleep 1
sudo docker image rm $(sudo docker image ls -aq) -f
sleep 1
sudo docker network rm $(sudo docker network ls --format '{{.Name}}' | grep -v 'bridge' | grep -v 'host' | grep -v 'none')
sleep 1
sudo docker volume prune -f
sleep 1
sudo docker network prune -f
sleep 1
sudo docker system prune -f
sleep 1
sudo docker builder prune -f

sudo rm /var/lib/docker/volumes/* -rf
