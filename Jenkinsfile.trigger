#!groovy


timestamps {
    def CANNED_CI_MESSAGE = '{"build_id":1404149,"old":0,"name":"mirrormanager2","task_id":38507123,"attribute":"state","request":["git+https://src.fedoraproject.org/rpms/mirrormanager2.git#763ae90d00b4735a32c96407103e4a4e31360de6","f30-candidate",{}],"instance":"primary","epoch":null,"version":"0.11","owner":"adrian","new":1,"release":"1.fc30"}'

    def libraries = ['fedora-ci-generic-checks': ['master', 'https://github.com/tflink/fedora-ci-generic-checks.git'],
                     'cico-pipeline'           : ['master', 'https://github.com/CentOS/cico-pipeline-library.git'],
                     'contra-lib'              : ['master', 'https://github.com/openshift/contra-lib.git']]

    libraries.each { name, repo ->
        library identifier: "${name}@${repo[0]}",
                retriever: modernSCM([$class: 'GitSCMSource',
                                      remote: repo[1]])

    }

    // send staging messages
    env.MSG_PROVIDER = "fedora-fedmsg-stage"

    properties(
            [
                    buildDiscarder(logRotator(artifactDaysToKeepStr: '', artifactNumToKeepStr: '500', daysToKeepStr: '', numToKeepStr: '500')),
                    parameters(
                            [
                                    //string(description: 'fedora-fedmsg', defaultValue: '{}', name: 'CI_MESSAGE')
                                    string(description: 'fedora-fedmsg', defaultValue: CANNED_CI_MESSAGE, name: 'CI_MESSAGE')
                            ]
                    ),
                    pipelineTriggers(
                            [[$class: 'CIBuildTrigger',
                              noSquash: true,
                              providerData: [
                                  $class: 'FedMsgSubscriberProviderData',
                                  name: 'fedora-fedmsg',
                                  overrides: [
                                      topic: 'org.fedoraproject.prod.buildsys.task.state.change'
                                  ],
                                  checks: [
                                      [field: 'new', expectedValue: '1|CLOSED'],
                                      [field: 'owner', expectedValue: '^(?!koschei).*']
                                  ]
                              ]
                            ]]
                    )
            ]
    )

    def TRIGGER_RETRY_COUNT = 3
    def stepName = null

    node('master') {
        buildCheckUtils.ciPipeline {
            try {
                stepName = 'extract information'
                stage(stepName) {
                    buildCheckUtils.handlePipelineStep(stepName: stepName, debug: true) {

                    print "CI_MESSAGE"
                    print CI_MESSAGE

                    parsedMsg = kojiMessage(message: env.CI_MESSAGE, ignoreErrors: true)
                    primaryKoji = parsedMsg['instance'] == "primary"
                    env.task_id = parsedMsg['task_id']
                    currentBuild.displayName = "BUILD#: ${env.BUILD_NUMBER}"

                    // we only care about koji-builds for now
                    env.artifact = 'koji-build'

                    // set env vars needed for sending messages
                    buildCheckUtils.setDefaultEnvVars()
                    buildCheckUtils.setScratchVars(parsedMsg)
                    }
                }

                stepName = 'schedule build'
                stage(stepName) {

                    if (primaryKoji && !env.isScratch.toBoolean()) {
                    checks = ['rpminspect']
                        for(checkname in checks) {

                            retry(TRIGGER_RETRY_COUNT) {
                                buildCheckUtils.handlePipelineStep(stepName: stepName, debug: true) {

                                build job: "fedora-${checkname}",
                                    // Scratch messages from task.state.changed call it id, not task_id
                                    parameters: [string(name: 'PROVIDED_KOJI_TASKID', value: env.task_id),
                                                string(name: 'CI_MESSAGE', value: env.CI_MESSAGE)],
                                    wait: false
                                }
                            }
                            messageFields = buildCheckUtils.setTestMessageFields("queued", artifact, parsedMsg)
                            buildCheckUtils.sendMessage(messageFields['topic'], messageFields['properties'], messageFields['content'])

                        }
                    }
                }
            } catch (e) {
                currentBuild.result = 'FAILURE'
                throw e
            }
        }
    }
}

