let re = "(" + profList.join("|") + ")\\b";
const regTest = new RegExp(re, "i");

document.addEventListener("DOMContentLoaded", () => {
    const viewmodel = new Vue({
        el: "#app",
        vuetify: new Vuetify({ theme: { dark: true } }),
        data: {
            visible: false,
            characters: [],
            chardata: {},
            show: {
                loading: false,
                characters: false,
                register: false,
                delete: false,
            },
            registerData: {
                date: new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().substr(0, 10),
                firstname: undefined,
                lastname: undefined,
                nationality: undefined,
                gender: undefined,
            },
            allowDelete: false,
            dataPickerMenu: false,
            characterAmount: 0,
            loadingText: "",
            selectedCharacter: -1,
            dollar: Intl.NumberFormat("en-US"),
            translations: {},
            customNationality: false,
            nationalities: [],
        },
        methods: {
            click_character: function (idx, type) {
                this.selectedCharacter = idx;

                if (this.characters[idx] !== undefined) {
                    axios.post("https://qb-multicharacter/cDataPed", {
                        cData: this.characters[idx],
                    });
                } else {
                    axios.post("https://qb-multicharacter/cDataPed", {});
                    // For empty slots, immediately show the registration form
                    if (type === "empty") {
                        this.resetRegisterData();
                        this.show.characters = false;
                        this.show.register = true;
                    }
                }
            },
            prepareDelete: function () {
                this.show.characters = false;
                this.show.delete = true;
            },
            cancelDelete: function () {
                this.show.delete = false;
                this.show.characters = true;
            },
            cancelCreate: function () {
                this.show.register = false;
                this.show.characters = true;
            },
            delete_character: function () {
                if (this.show.delete) {
                    this.show.delete = false;
                    axios.post("https://qb-multicharacter/removeCharacter", {
                        citizenid: this.characters[this.selectedCharacter].citizenid,
                    });
                    setTimeout(() => {
                        this.show.characters = true;
                    }, 500);
                }
            },
            play_character: function () {
                if (this.selectedCharacter !== -1) {
                    var data = this.characters[this.selectedCharacter];

                    if (data !== undefined) {
                        axios.post("https://qb-multicharacter/selectCharacter", {
                            cData: data,
                        });
                        setTimeout(() => {
                            this.show.characters = false;
                        }, 500);
                    } else {
                        this.resetRegisterData();
                        this.show.characters = false;
                        this.show.register = true;
                    }
                }
            },
            resetRegisterData: function () {
                this.show.characters = false;
                this.show.register = true;
                this.registerData = {
                    date: new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().substr(0, 10),
                    firstname: undefined,
                    lastname: undefined,
                    nationality: undefined,
                    gender: undefined,
                };
            },
            create_character: function () {
                const registerData = this.registerData;
                const validationResult = characterValidator.validateCharacter({
                    firstname: registerData.firstname,
                    lastname: registerData.lastname,
                    nationality: registerData.nationality,
                    gender: registerData.gender,
                    date: registerData.date,
                });

                if (validationResult.isValid) {
                    this.show.register = false;

                    axios.post("https://qb-multicharacter/createNewCharacter", {
                        firstname: registerData.firstname,
                        lastname: registerData.lastname,
                        nationality: registerData.nationality,
                        birthdate: registerData.date,
                        gender: registerData.gender,
                        cid: this.selectedCharacter,
                    });

                    setTimeout(() => {
                        this.show.characters = false;
                    }, 500);
                } else {
                    Swal.fire({
                        icon: "error",
                        title: this.translate("ran_into_issue"),
                        text: this.translate(validationResult.message, { field: this.translate(validationResult.field) }),
                        timer: 5000,
                        timerProgressBar: true,
                        showConfirmButton: false,
                    });
                }
            },
            translate(key, params) {
                if (params) {
                    return translationManager.formatTranslation(key, params);
                }
                return translationManager.translate(key);
            },
        },
        mounted() {
            initializeValidator();
            var loadingProgress = 0;
            var loadingDots = 0;
            window.addEventListener("message", (event) => {
                var data = event.data;
                switch (data.action) {
                    case "ui":
                        this.visible = data.toggle;
                        // [BugFix] 当 toggle=false（关闭消息）时，提前 break，避免访问
                        // undefined 的 translations/countries/nChar 等字段导致 JS 异常，
                        // 阻断 Vue 的 v-show 响应更新，造成黑色 NUI 层残留覆盖游戏画面。
                        if (!data.toggle) {
                            this.show.loading = false;
                            this.show.characters = false;
                            this.show.register = false;
                            this.show.delete = false;
                            this.selectedCharacter = -1;
                            break;
                        }
                        this.customNationality = event.data.customNationality;
                        translationManager.setTranslations(event.data.translations);
                        this.translations = event.data.translations;
                        this.nationalities = event.data.countries;
                        this.characterAmount = data.nChar;
                        this.selectedCharacter = -1;
                        this.show.register = false;
                        this.show.delete = false;
                        this.show.characters = false;
                        this.allowDelete = event.data.enableDeleteButton;
                        EnableDeleteButton = data.enableDeleteButton;

                        if (data.toggle) {
                            this.show.loading = true;
                            this.loadingText = this.translate("retrieving_playerdata");
                            var DotsInterval = setInterval(() => {
                                loadingDots++;
                                loadingProgress++;
                                if (loadingProgress == 3) {
                                    this.loadingText = this.translate("validating_playerdata");
                                }
                                if (loadingProgress == 4) {
                                    this.loadingText = this.translate("retrieving_characters");
                                }
                                if (loadingProgress == 6) {
                                    this.loadingText = this.translate("validating_characters");
                                }
                                if (loadingDots == 4) {
                                    loadingDots = 0;
                                }
                            }, 500);

                            setTimeout(() => {
                                axios.post("https://qb-multicharacter/setupCharacters");
                                setTimeout(() => {
                                    clearInterval(DotsInterval);
                                    loadingProgress = 0;
                                    this.loadingText = this.translate("retrieving_playerdata");
                                    this.show.loading = false;
                                    this.show.characters = true;
                                    axios.post("https://qb-multicharacter/removeBlur");
                                }, 2000);
                            }, 2000);
                        }
                        break;
                    case "setupCharacters":
                        var newChars = [];
                        for (var i = 0; i < event.data.characters.length; i++) {
                            newChars[event.data.characters[i].cid] = event.data.characters[i];
                        }
                        this.characters = newChars;
                        
                        // 自动选中第一个有效角色进行 3D 预览（使用 dense 数组判断以防 sparse 数组长度计算不准）
                        if (event.data.characters && event.data.characters.length > 0) {
                            for (var idx = 1; idx <= this.characterAmount; idx++) {
                                if (this.characters[idx] !== undefined) {
                                    this.click_character(idx, 'existing');
                                    break;
                                }
                            }
                        }
                        break;
                    case "setupCharInfo":
                        this.chardata = event.data.chardata;
                        break;
                    case "forceHide":
                        // [核心NUI黑屏修复] 完全绕过 Vue 响应式，直接操作 DOM
                        // 无论 Vue 的 v-show/v-if 状态如何，强制隐藏整个 NUI 内容层
                        (function() {
                            var appEl = document.getElementById('app');
                            if (appEl) {
                                appEl.style.visibility = 'hidden';
                                appEl.style.opacity = '0';
                                appEl.style.pointerEvents = 'none';
                            }
                            // 同时直接隐藏 main-screen（黑色背景来源）
                            var screens = document.querySelectorAll('.main-screen, .container, .v-application--wrap');
                            screens.forEach(function(el) {
                                el.style.visibility = 'hidden';
                                el.style.opacity = '0';
                            });
                        })();
                        break;
                    case "forceShow":
                        // 恢复显示（角色选择界面再次打开时调用）
                        (function() {
                            var appEl = document.getElementById('app');
                            if (appEl) {
                                appEl.style.visibility = '';
                                appEl.style.opacity = '';
                                appEl.style.pointerEvents = '';
                            }
                            var screens = document.querySelectorAll('.main-screen, .container, .v-application--wrap');
                            screens.forEach(function(el) {
                                el.style.visibility = '';
                                el.style.opacity = '';
                            });
                        })();
                        break;
                }
            });
        },
    });
});
