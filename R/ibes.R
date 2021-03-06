library(tidyverse)
library(lubridate)
library(readxl)

# reading ibes detail histotry data -> entire database, us file, fy1, q1, q2, q3 and q4, only eps and from 1997-01 to 2011-01

detail_raw <- read_tsv("data/ibes_data_detail_history_detail.txt", col_types = cols(.default = "c"))

# renaming, formatting and selecting the variables

detail_temp1 <- detail_raw %>%
  transmute(ibes_ticker = TICKER,
            cusip = CUSIP,
            firm = CNAME,
            brokerage_code = ESTIMATOR,
            analyst = ANALYS,
            forecast_period_id = FPI,
            measure = MEASURE,
            eps_value = parse_double(VALUE),
            forecast_period_end_date = ymd(FPEDATS),
            announce_date = ymd(ANNDATS)) %>% # date when forecast was reported
  select(-measure, -forecast_period_id) %>%  # dropped, as not of particular interest
  filter(!is.na(cusip)) %>% # filter NA Cusips away, since can not be linked to other datasources
  distinct()


# closure events from Kelly and Ljungqvist (2012) Appendix list

# brokerages and codes that closed mapped by ibes_names.csv


closures_raw <- read_excel("data/closure_events.xlsx")
closures <- closures_raw %>% 
  transmute(brokerage_code = str_pad(brokerage_code, 5, side = c("left"), pad = "0"),
            brokerage_name_ibes = `brokerage_name (from ibes_names)`,
            brokerage_name = `brokerage_name (from Appendix list)`,
            event_date = ymd(event_date),
            event_date_temp1 = event_date %m-% months(12))

write_rds(closures, "data/closures.rds")

events <- closures %>%
  select(event_date, event_date_temp1) %>% 
  distinct()

brokerage_codes_list <- list(closures$brokerage_code) %>% 
  flatten_chr()

# read stopped_estimates from ibes to filter out analysts that stopped before the closure_event_date

stopped_raw <- read_tsv("data/ibes_data_detail_stopped_estimate.txt",  col_types = cols(.default = "c"))

stopped <- stopped_raw %>%
  transmute(ibes_ticker = TICKER,
            brokerage_code = ESTIMATOR,
            announce_stop_date = ymd(ASTPDATS), # date when forecast stopped
            forecast_period_end_date = ymd(FPEDATS)) %>% 
  distinct() %>% 
  arrange(ibes_ticker, brokerage_code, announce_stop_date)

# left join detail data and stopped analysts data

detail_temp2 <- detail_temp1 %>% 
  left_join(stopped, by = c("ibes_ticker", "brokerage_code", "forecast_period_end_date"))

# left join detail data and closure_dates

detail_temp3 <- detail_temp2 %>% 
  left_join(closures, by = c("brokerage_code")) %>% 
  select(-brokerage_name_ibes)

# filter brokerages that are in the closed_brokerages list (i.e. treatment group)

detail_temp4 <- detail_temp3 %>% 
  filter(!is.na(event_date)) %>% # have to have a closure date to be in treatment group
  mutate(yearbefore = announce_date %within% interval(event_date %m-% months(12), event_date %m+% months(3))) %>% 
  filter(yearbefore == T) %>%  # filter only analysts that actively "covers" the firm, see Derrien and Keckses (2013) p. 1411
  #mutate(announce_stop_date = if_else(is.na(announce_stop_date), event_date %m-% months(12), announce_stop_date)) %>% 
  filter(announce_stop_date > event_date %m-% months(3) | is.na(announce_stop_date) == T)
  #filter(stopped_before == F)  # filter only firms of which analysts have not stopped before event_date (relax 3 months)
                                    # otherwise endogenous "stoppings", i.e. decided to stop covering

treated_firms_temp1 <- detail_temp4 %>% 
  group_by(cusip, event_date, brokerage_name) %>% 
  summarise(treated = 1,
            after= 0) %>% 
  ungroup()

treated_firms_temp2 <- detail_temp4 %>% 
  group_by(cusip, event_date, brokerage_name) %>% 
  summarise(treated = 1,
            after= 1) %>% 
  ungroup()

treated_firms <- bind_rows(treated_firms_temp1, treated_firms_temp2) %>% 
  arrange(cusip, event_date)


# control group

yearbefore_list <- map2(events$event_date_temp1, events$event_date,
                        ~seq(.x, .y, "day") %>% as.character) %>% 
  flatten_chr() %>% 
  ymd()

all_firms_temp1 <- detail_temp3 %>% 
  mutate(inyearbeforelist = announce_date %in% yearbefore_list) %>% 
  filter(inyearbeforelist == T) %>% # require control to be "actively" covered, i.e. year before
  group_by(cusip, announce_date) %>% 
  summarise(k = 1) %>% 
  ungroup()

closures_temp1 <- closures %>%
  select(event_date, brokerage_name) %>% 
  mutate(k = 1)

all_firms <- inner_join(all_firms_temp1, closures_temp1, by = 'k') %>% 
  select(-k) %>%
  distinct()

control_firms_temp1 <- all_firms %>% 
  mutate(yearbefore = announce_date %within% interval(event_date %m-% months(12), event_date)) %>%
  filter(yearbefore == T) %>% # potential controls have to be similarly actively covered year before
  anti_join(treated_firms, by = c("cusip", "event_date", "brokerage_name"))

control_firms_temp2 <- control_firms_temp1 %>%
  select(-announce_date, -yearbefore) %>% 
  distinct() %>% 
  mutate(treated = 0,
         after = 0)

control_firms_temp3 <- control_firms_temp2 %>%
  mutate(treated = 0,
         after = 1)
  
control_firms <- bind_rows(control_firms_temp2, control_firms_temp3) %>% 
  arrange(cusip, event_date)


## identified firms to either treatment group (treated = 1) or control group (treated = 0) for each event date

ibes_did_raw_temp <- bind_rows(treated_firms, control_firms) %>% 
  arrange(cusip, event_date)

quarters <- tibble(quarter_index = c(-12:-1, 1:12),
                   k = if_else(quarter_index < 0, 1, 2))

ibes_did_raw <- ibes_did_raw_temp %>%
  mutate(k = if_else(after == 0, 1, 2)) %>% 
  left_join(quarters, by = "k") %>% 
  select(-k)

## total analyst coverage, used for calculating number of distinct analysts

analyst_coverage <- detail_temp3 %>%
  select(cusip, announce_date, analyst) %>% 
  arrange(cusip, announce_date, analyst) %>% 
  distinct()

#### calculating distinct analysts during the given events-intervals, for each event and for each stock (cusip)

## elegant way

quarter_index <- c(1:12) # 12 quarters = 3 years

before_interval_fun <- function (event_date, quarter_index) {
  i <- 3 + (quarter_index - 1) * 3
  j <- 3 + (quarter_index) * 3
  g <- if_else(event_date == ceiling_date(event_date, unit = "quarter") - days(1), 
               floor_date(event_date %m-% months(i), unit ="quarter"), 
               floor_date(event_date %m-% months(j), unit = "quarter"))
  j <- if_else(event_date == ceiling_date(event_date, unit = "quarter") - days(1), 
               ceiling_date(event_date %m-% months(i), unit ="quarter") - days(1), 
               ceiling_date(event_date %m-% months(j), unit = "quarter") - days(1))
  df <- tibble(event_date = event_date,
               interval = interval(g, j),
               quarter_index = quarter_index)
  df
}

after_interval_fun <- function (event_date, quarter_index) {
  i <- (quarter_index - 1) * 3
  j <- (quarter_index) * 3
  g <- ceiling_date(event_date %m+% months(i), unit = "quarter")
  j <- ceiling_date(event_date %m+% months(j), unit = "quarter") - days(1)
  df <- tibble(event_date = event_date,
               interval = interval(g, j),
               quarter_index = quarter_index)
  df
}

filter1 <- function (df_measures, df_events){
  interval <- df_events$interval  
  filter(df_measures, announce_date %within% interval)
}
 
summarise1 <- function (df) {
  df %>% 
    group_by(cusip, event_date, quarter_index) %>% 
    summarise(result = n_distinct(analyst)) %>% 
    ungroup()
}

# map every before_interval (12) to every distinct event_date (20) and flatten to list of 12*20
# do the filtering for list of data frames based on intervals and add columns event_date and year_index
# do the summarising for the measure of interest (number of distinct analysts in this case)
# and set corresponding after value (before = 0, after = 1)

before_val <- map(quarter_index, ~map(events$event_date, ~before_interval_fun(.x, .y), .y = .x)) %>%
  flatten() %>% 
  map(~filter1(analyst_coverage, .x) %>%
        mutate(event_date = .x$event_date,
               quarter_index = .x$quarter_index)) %>% 
  map_df(~summarise1(.x)) %>% 
  rename(analyst_coverage = result) %>% 
  mutate(after = 0,
         quarter_index = (-1)*quarter_index) %>% 
  arrange(cusip, event_date, quarter_index)

after_val <- map(quarter_index, ~map(events$event_date, 
                                  ~after_interval_fun(.x, .y), .y = .x)) %>% 
  flatten() %>% 
  map(~filter1(analyst_coverage, .x) %>%
        mutate(event_date = .x$event_date,
               quarter_index = .x$quarter_index)) %>% 
  map_df(~summarise1(.x)) %>% 
  rename(analyst_coverage = result) %>% 
  mutate(after = 1) %>% 
  arrange(cusip, event_date, quarter_index)

vals <- bind_rows(before_val, after_val) %>% 
  select(-after)

ibes_did <- ibes_did_raw %>% 
  left_join(vals, by = c("cusip", "event_date", "quarter_index")) %>% 
  distinct() %>% 
  mutate(analyst_coverage =  if_else(is.na(analyst_coverage) == T, 0L, analyst_coverage))

write_rds(ibes_did, "data/ibes_did.rds")

i <- ibes_did %>% 
  mutate(TREATED = if_else(treated == 1, "Treated", "Control")) %>%
  group_by(TREATED, quarter_index, event_date) %>% 
  summarise(analyst_coverage = mean(analyst_coverage)) %>% 
  ungroup() %>% 
  mutate(AFTER = if_else(quarter_index < 0, 0, 1))
  
j <- ibes_did %>% 
  filter(quarter_index %in% c(-4:4)) %>% 
  group_by(event_date, treated, after, cusip) %>% 
  summarise(analyst_coverage_mean = mean(analyst_coverage),
            analyst_coverage_med = median(analyst_coverage)) %>% 
  ungroup() %>% 
  mutate(year = lubridate::year(event_date))

i %>% 
  ggplot(aes(quarter_index, analyst_coverage, color = TREATED)) +
  geom_line() +
  labs(x = "Event quarter", color = "") +
  geom_vline(xintercept=0) +
  theme_classic() +
  theme(plot.title = element_text(size=9, face="italic")) +
  scale_color_grey(start = 0.55, end = 0) + 
  facet_wrap(.~ event_date)

library(lfe)
f <- felm(analyst_coverage_med ~ treated + after + after*treated | year |0 | year, j)
summary(f)
