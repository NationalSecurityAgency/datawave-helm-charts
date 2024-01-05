## Generate Image Pull Secrets ##
Running this stack uses images in the ghcr repository which are not public. The following generates a template to use for imagePullSecrets in helm charts.


Through the GitHub UI, generate a PAT with at least read packages

```
./create-image-pull-secrets.sh <github username> <gihub PAT>
```


### DataWave Stack Helm Deployment ###

This repository holds Helm charts and Docker files used to deploy Datawave locally for testing. 

Prerequisites:

* docker
* helm
* kubectl
* minikube (for local testing)


If you already have the prerequisites installed you can simply run `./startLocalTest.sh`





## Testing of images and helm charts ##

Images are now created in [Datawave Stack Docker Images](https://github.com/nationalSecurityAgency/datawave-stack-docker-images)

In order to test changes to helm charts, you can run the following script:
```
./startLocalTest.sh
```
This will package all the helm charts from the local directories, and launch the cluster.