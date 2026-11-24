# Earworm

Вебапка Діми: англійська на слух по YouTube. Сайт: гілка `gh-pages` (GitHub Pages).
Ця гілка (`earworm`) — код. Кожне оновлення гілки запускає збірку (`.github/workflows/earworm.yml`):
пошук відео і текстів (`build.py`, каталог у `seed.json`), переклад (`translate_google.py`), викладання сайту в `gh-pages`.
Гілку `main` (застосунок voice) це не зачіпає.
