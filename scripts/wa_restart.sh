#  Restart WA pods. Run script after changing project to where WA is installed.
#  Author - Manu Thapar
# Copyright 2021 IBM Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http:#www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

INSTANCE="wa" # Replace Watson Assistant instance name if different
for DEPLOYMENT in ed dragonfly-clu-mm tfmm clu-serving master nlu dialog store
do
echo "#Starting rolling restart of $INSTANCE-$DEPLOYMENT."
oc rollout restart deployment $INSTANCE-$DEPLOYMENT
oc rollout status deployment/$INSTANCE-$DEPLOYMENT --watch=true
echo "#Rolling restart of $INSTANCE-$DEPLOYMENT completed successfully."
done

for DEPLOYMENT in analytics clu-embedding incoming-webhooks integrations recommends spellchecker-mm store-sync system-entities ui webhooks-connector gw-instance store-admin
do
echo "#Starting rolling restart of $INSTANCE-$DEPLOYMENT"
oc rollout restart deployment $INSTANCE-$DEPLOYMENT
done

for DEPLOYMENT in analytics clu-embedding incoming-webhooks integrations recommends spellchecker-mm store-sync system-entities ui webhooks-connector gw-instance store-admin
do
oc rollout status deployment/$INSTANCE-$DEPLOYMENT --watch=true
echo "#Rolling restart of $INSTANCE-$DEPLOYMENT completed successfully."
done
echo "#All Watson Assistant deployments restarted successfully."
