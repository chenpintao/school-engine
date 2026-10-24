import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

const MOODS = [
  { value: 1, emoji: "😞" },
  { value: 2, emoji: "😕" },
  { value: 3, emoji: "😐" },
  { value: 4, emoji: "🙂" },
  { value: 5, emoji: "😄" },
];

export default class SchoolMoodBar extends Component {
  @service currentUser;

  constructor(owner, args) {
    super(owner, args);
    this.load();
  }

  @tracked loaded = false;
  @tracked todayMood = null;
  @tracked moodEnabled = true;
  @tracked editing = false;

  // 组件挂在 welcome-banner-below-headline 出口内——横幅只在欢迎页出现，
  // 因此"哪里有欢迎横幅，哪里就有心情签到"，无需再做路由判断。
  get show() {
    return this.currentUser && this.moodEnabled;
  }

  moods = MOODS;

  get currentMood() {
    return MOODS.find((m) => m.value === this.todayMood);
  }

  get currentMoodName() {
    return this.todayMood ? i18n(`school_engine.mood_name_${this.todayMood}`) : "";
  }

  get showPicker() {
    return !this.todayMood || this.editing;
  }

  moodLabel = (value) => i18n(`school_engine.mood_name_${value}`);

  load() {
    if (!this.currentUser) {
      this.loaded = true;
      return;
    }
    ajax("/school/feed.json")
      .then((data) => {
        this.todayMood = data.today_mood;
        this.moodEnabled = data.mood_enabled !== false;
        this.loaded = true;
      })
      .catch(() => {
        this.loaded = true;
      });
  }

  @action
  selectMood(mood) {
    ajax("/school/mood-checkin.json", { type: "POST", data: { mood } })
      .then((data) => {
        this.todayMood = data.mood;
        this.editing = false;
      })
      .catch(popupAjaxError);
  }

  @action
  startEdit() {
    this.editing = true;
  }

  <template>
    {{#if this.show}}
      <div class="school-mood-bar">
        {{#if this.showPicker}}
          <span class="school-mood-bar-label">
            {{i18n "school_engine.mood_today"}}
          </span>
          <div class="school-mood-bar-picker" role="group">
            {{#each this.moods as |mood|}}
              <button
                type="button"
                class="school-mood-bar-btn"
                title={{fn this.moodLabel mood.value}}
                aria-label={{fn this.moodLabel mood.value}}
                {{on "click" (fn this.selectMood mood.value)}}
              >
                {{mood.emoji}}
              </button>
            {{/each}}
          </div>
        {{else}}
          <span class="school-mood-bar-current" title={{this.currentMoodName}}>
            {{this.currentMood.emoji}}
          </span>
          <button
            type="button"
            class="btn btn-small school-mood-bar-change-btn"
            {{on "click" this.startEdit}}
          >
            {{i18n "school_engine.mood_change"}}
          </button>
        {{/if}}
      </div>
    {{/if}}
  </template>
}
