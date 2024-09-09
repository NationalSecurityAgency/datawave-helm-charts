#!/usr/bin/env bash

USERNAME=$1
PAT=$2


BASE64ENCODEDTOKEN=`echo -n "${USERNAME}:${PAT}" | base64`


read -r -d '' FILETEXT << EOF
{
    "auths":
    {
        "ghcr.io":
            {
                "auth":"${BASE64ENCODEDTOKEN}"
            }
    }
}
EOF

FILE_ENCODED=`echo -n  "$FILETEXT" | base64 | tr -d '\n' `

cat > ./ghcr-image-pull-secret.yaml <<- EOF
kind: Secret
type: kubernetes.io/dockerconfigjson
apiVersion: v1
metadata:
  name: dockerconfigjson-ghcr
  labels:
    app: app-name
data: 
  .dockerconfigjson: ${FILE_ENCODED}
EOF

