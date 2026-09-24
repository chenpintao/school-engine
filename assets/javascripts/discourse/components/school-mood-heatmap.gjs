import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

/**
 * 个人主页「心情记录」热力图：GitHub contribution 风格。
 * 7 行 = 周一到周日（DOM 顺序周日→周六，一列 = 一周），共约 18 周；
 * 未签到灰色（--primary-low），签到按心情着色（SCSS .mood-1..5，color-mix 混合
 * 主题表面色，浅色/深色主题都协调）。数据 GET /school/moods/:username.json。
 */
const WEEKS = 18;

function localIso(date) {
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${date.getFullYear()}-${month}-${day}`;
}

export default class SchoolMoodHeatmap extends Component {
  @tracked moodMap = {};
  @tracked loaded = false;

  // 构造时即发起加载（无需 DOM 元素），避免依赖 render-modifiers。
  constructor(owner, args) {
    super(owner, args);
    this.load();
  }

  get username() {
    return this.args.user?.username;
  }

  // 无任何签到记录（含心情功能关闭、服务端返回空）时整块隐藏
  get hasMood() {
    return Object.keys(this.moodMap).length > 0;
  }

  get columns() {
    if (!this.loaded) {
      return [];
    }

    const today = new Date();
    today.setHours(0, 0, 0, 0);

    const start = new Date(today);
    start.setDate(start.getDate() - (WEEKS * 7 - 1));
    start.setDate(start.getDate() - start.getDay()); // 回到周日，保证列对齐

    const columns = [];
    const cursor = new Date(start);
    let index = 0;

    while (cursor <= today) {
      const columnIndex = Math.floor(index / 7);
      (columns[columnIndex] ||= []);

      const iso = localIso(cursor);
      const mood = this.moodMap[iso];
      columns[columnIndex].push({
        iso,
        cls: mood ? `mood-${mood}` : "mood-empty",
        title: mood
          ? `${iso} · ${i18n(`school_engine.mood_name_${mood}`)}`
          : `${iso} · ${i18n("school_engine.mood_not_checked")}`,
      });

      cursor.setDate(cursor.getDate() + 1);
      index += 1;
    }

    return columns;
  }

  load() {
    if (!this.username) {
      return;
    }
    ajax(`/school/moods/${this.username}.json?days=${WEEKS * 7}`)
      .then((data) => {
        this.moodMap = data.moods || {};
        this.loaded = true;
      })
      .catch(() => {
        this.loaded = true;
      });
  }

  <template>
    <section class="school-mood-heatmap">
      {{#if this.hasMood}}
        <h2 class="school-mood-heatmap-heading">
          {{i18n "school_engine.mood_heatmap_title"}}
        </h2>
        <div class="school-mood-heatmap-grid">
          {{#each this.columns as |column|}}
            <div class="school-mood-col">
              {{#each column as |cell|}}
                <span
                  class="school-mood-cell {{cell.cls}}"
                  title={{cell.title}}
                ></span>
              {{/each}}
            </div>
          {{/each}}
        </div>
      {{/if}}
    </section>
  </template>
}
