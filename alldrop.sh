sudo docker stack rm $(sudo docker stack ls --format '{{.Name}}')
sleep 1
sudo docker volume prune -f
sleep 1
sudo docker network prune -f
sleep 1
sudo docker system prune -f
sleep 1
sudo docker builder prune -f

#sudo rm /var/lib/docker/volumes/* -rf
